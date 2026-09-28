import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // surround-profil vit dans ~/.local/bin, absent du PATH de plasmashell :
    // on passe par un shell pour que $HOME soit resolu.
    readonly property string bin: "$HOME/.local/bin/surround-profil"

    property string currentProfile: "…"
    property bool sinkActive: false
    property bool busy: false
    property string activeHeadphone: "none"
    property int envelope: 0
    property bool envelopeAvailable: false
    property string searchHint: ""
    // Derniere sortie de --sync, reference du polling rapide.
    property string lastState: ""

    // En deca de ce seuil, une recherche renverrait des centaines d'entrees sans
    // interet et lancerait un processus a chaque frappe.
    readonly property int minChars: 3
    // Au-dela, on fait defiler plutot que d'agrandir : la fenetre du plasmoide
    // est deja juste en hauteur.
    readonly property int maxVisibleRows: 8

    Plasma5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []

        property var callbacks: ({})

        function run(command, callback) {
            const key = "sh -c " + "'" + bin + " " + command + "'";
            callbacks[key] = callback;
            connectSource(key);
        }

        onNewData: (source, data) => {
            const callback = callbacks[source];
            delete callbacks[source];
            disconnectSource(source);
            if (callback) {
                callback(("" + data["stdout"]).trim(), data["exit code"]);
            }
        }
    }

    ListModel { id: profileModel }
    ListModel { id: headphoneModel }
    ListModel { id: searchModel }

    function refresh() {
        shell.run("--data", function (output) {
            profileModel.clear();
            for (const line of output.split("\n")) {
                if (!line) continue;
                const c = line.split("\t");
                if (c.length < 6) continue;
                // Un profil ajoute par l'utilisateur n'a pas ete mesure :
                // ses colonnes sont vides et les pastilles restent masquees,
                // plutot que d'afficher des valeurs inventees.
                profileModel.append({
                    name: c[0], usage: c[1],
                    measured: c[2] !== "",
                    lat: c[2] === "" ? 0 : parseInt(c[2]),
                    reverb: c[3] === "" ? 0 : parseInt(c[3]),
                    note: c[4], isActive: c[5] === "1"
                });
                if (c[5] === "1") root.currentProfile = c[0];
            }
        });
        shell.run("--status", function (output, code) {
            root.sinkActive = (code === 0);
        });
        shell.run("--envelope-available", function (output) {
            root.envelopeAvailable = (output.trim() === "1");
        });
        shell.run("--envelope-current", function (output) {
            const v = parseInt(output.trim());
            if (!isNaN(v)) root.envelope = v;
        });
        shell.run("--headphone-data", function (output) {
            headphoneModel.clear();
            for (const line of output.split("\n")) {
                if (!line) continue;
                const c = line.split("\t");
                if (c.length < 2) continue;
                if (c[1] === "1") root.activeHeadphone = c[0];
                headphoneModel.append({ name: c[0] });
            }
        });
        // Reference du polling a jour : sans cela, le cycle suivant verrait un
        // changement et rechargerait tout une seconde fois.
        shell.run("--sync", function (output) {
            root.lastState = output;
        });
    }

    // Champ vide : on montre ce qui est deja telecharge. Des qu'on tape, on
    // interroge l'index complet des 8850 casques mesures. Un seul champ couvre
    // donc les deux usages, sans occuper de hauteur supplementaire.
    function searchHeadphones(pattern) {
        if (pattern.indexOf('"') >= 0 || pattern.indexOf("'") >= 0) return;
        if (pattern.length > 0 && pattern.length < minChars) {
            searchModel.clear();
            root.searchHint = i18np("Type at least %1 character",
                                    "Type at least %1 characters", minChars);
            return;
        }
        root.searchHint = "";
        if (pattern.length === 0) {
            searchModel.clear();
            for (let i = 0; i < headphoneModel.count; i++) {
                searchModel.append({
                    name: headphoneModel.get(i).name, source: "", installed: true
                });
            }
            return;
        }
        shell.run('--headphone-search-data "' + pattern + '"', function (output) {
            searchModel.clear();
            for (const line of output.split("\n")) {
                if (!line) continue;
                const c = line.split("\t");
                if (c.length < 3) continue;
                searchModel.append({
                    name: c[0], source: c[1], installed: c[2] === "1"
                });
            }
        });
    }

    // Applique a la relache seulement : chaque valeur regenere le profil et
    // recharge la chaine, ce qui serait absurde a chaque pixel du curseur.
    function setEnvelope(v) {
        if (busy) return;
        busy = true;
        shell.run("--envelope " + Math.round(v), function () {
            busy = false;
            refresh();
        });
    }

    function switchHeadphone(name) {
        if (busy) return;
        // Un nom porteur de guillemets casserait la commande passee au shell.
        if (name.indexOf('"') >= 0 || name.indexOf("'") >= 0) return;
        busy = true;
        const cmd = (name === "none") ? "--headphone-none" : '--headphone "' + name + '"';
        shell.run(cmd, function () {
            busy = false;
            refresh();
        });
    }

    function switchProfile(name) {
        if (busy || name === currentProfile) return;
        busy = true;
        // Le changement ne recharge que l'instance dediee : ~0.15 s, sans
        // toucher au serveur audio principal ni aux autres flux.
        shell.run(name, function () {
            busy = false;
            refresh();
        });
    }

    Component.onCompleted: refresh()

    // Un changement fait depuis le terminal doit apparaitre aussitot. --sync
    // renvoie une ligne compacte (profil, enveloppe, casque) qu'on compare a la
    // precedente : le modele complet n'est recharge que si elle a change.
    Timer {
        interval: 500; running: true; repeat: true
        onTriggered: {
            if (root.busy) return;
            shell.run("--sync", function (output) {
                if (output !== root.lastState) {
                    root.lastState = output;
                    root.refresh();
                }
            });
        }
    }

    // --sync ne voit ni l'etat du sink, ni un profil depose dans le dossier,
    // ni le generateur installe apres coup : un rechargement complet periodique
    // reste necessaire pour ceux-la.
    Timer {
        interval: 30000; running: true; repeat: true
        onTriggered: if (!root.busy) root.refresh()
    }

    // Icone deposee par install.sh dans le theme hicolor de l'utilisateur.
    // On la designe par son NOM, pas par un chemin : c'est ce qu'attendent le
    // navigateur de widgets et le moteur d'icones, et c'est ce qui declenche
    // la recoloration selon le theme clair ou sombre.
    readonly property string appIcon: "org.spatialsound.kde"
    Plasmoid.icon: appIcon
    toolTipMainText: i18n("Spatial Sound")
    toolTipSubText: sinkActive
        ? i18n("Profile: %1", currentProfile)
        : i18n("Virtual sink inactive")

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.fill: parent
            source: root.appIcon
            isMask: true          // teinte par la couleur de texte du panneau
            opacity: root.sinkActive ? 1.0 : 0.5
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 22
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        // Trois lignes de pied se sont ajoutees depuis (legende, casque,
        // amortissement) : la hauteur demandee ne suffisait plus et le popup se
        // retrouvait plafonne par cette valeur, pas par l'ecran. Plasma reduit
        // de lui-meme si la place manque.
        Layout.preferredHeight: Kirigami.Units.gridUnit * 38

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    PlasmaExtras.Heading {
                        level: 4
                        text: root.sinkActive ? root.currentProfile : i18n("Inactive")
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    PlasmaComponents.Label {
                        text: root.sinkActive
                            ? i18n("7.1 headphone surround")
                            : i18n("Run install.sh")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                PlasmaComponents.BusyIndicator {
                    running: root.busy
                    visible: running
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
            }
        }

        footer: PlasmaExtras.PlasmoidHeading {
            position: QQC.ToolBar.Footer
            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: i18n("dB = capacity to place sounds · ms = the longer, the more distant")
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }

                // Correction de casque : couche distincte des profils ci-dessus.
                // Elle compense la reponse du casque, elle ne place aucun son —
                // d'ou sa place a part, hors de la liste.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: i18n("Headphone:")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.8
                    }

                    PlasmaComponents.TextField {
                        id: headphoneField
                        Layout.fillWidth: true
                        enabled: !root.busy
                        // La correction active s'affiche en texte plein, pas en
                        // texte de substitution : celui-ci est gris pale et se lit
                        // comme un champ vide, ce qui masquait l'etat courant.
                        placeholderText: i18n("search a headphone…")

                        function reflectState() {
                            text = root.activeHeadphone === "none" ? "" : root.activeHeadphone;
                        }
                        Component.onCompleted: reflectState()
                        Connections {
                            target: root
                            function onActiveHeadphoneChanged() {
                                if (!headphoneField.activeFocus) headphoneField.reflectState();
                            }
                        }

                        // La recherche part sur pause de frappe : sans cela chaque
                        // caractere lancerait un processus.
                        Timer {
                            id: searchDelay
                            interval: 250
                            onTriggered: root.searchHeadphones(headphoneField.text)
                        }
                        onTextChanged: searchDelay.restart()
                        onActiveFocusChanged: {
                            if (activeFocus) {
                                // Le nom affiche est selectionne : taper le remplace
                                // au lieu de s'y ajouter.
                                selectAll();
                                root.searchHeadphones("");
                                headphonePopup.open();
                            } else {
                                reflectState();
                            }
                        }

                        QQC.Popup {
                            id: headphonePopup
                            y: -height - Kirigami.Units.smallSpacing
                            width: headphoneField.width
                            // Les resultats flottent au-dessus du champ : ils ne
                            // prennent aucune hauteur dans la mise en page, qui est
                            // deja juste.
                            readonly property real rowHeight:
                                Math.max(1, headphoneView.count) > 0 && headphoneView.contentHeight > 0
                                    ? headphoneView.contentHeight / Math.max(1, headphoneView.count)
                                    : Kirigami.Units.gridUnit * 2
                            height: root.searchHint !== ""
                                ? Kirigami.Units.gridUnit * 2
                                : Math.min(rowHeight * root.maxVisibleRows,
                                           headphoneView.contentHeight) + 2
                            padding: 1
                            visible: headphoneField.activeFocus
                                     && (searchModel.count > 0 || root.searchHint !== "")

                            PlasmaComponents.Label {
                                anchors.centerIn: parent
                                width: parent.width - Kirigami.Units.largeSpacing
                                visible: root.searchHint !== ""
                                text: root.searchHint
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }

                            contentItem: ListView {
                                id: headphoneView
                                clip: true
                                visible: root.searchHint === ""
                                model: searchModel
                                boundsBehavior: Flickable.StopAtBounds
                                QQC.ScrollBar.vertical: QQC.ScrollBar {
                                    policy: QQC.ScrollBar.AsNeeded
                                }
                                delegate: PlasmaComponents.ItemDelegate {
                                    width: ListView.view.width
                                    onClicked: {
                                        root.switchHeadphone(model.name);
                                        // Pas de vidage : la perte du focus remet
                                        // le champ sur la correction desormais active.
                                        headphoneField.focus = false;
                                    }
                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.smallSpacing
                                        PlasmaComponents.Label {
                                            // « none » est une valeur interne : on affiche son libelle traduit.
                                            text: model.name === "none" ? i18n("None") : model.name
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        PlasmaComponents.Label {
                                            text: model.source
                                            visible: model.source !== ""
                                            font: Kirigami.Theme.smallFont
                                            opacity: 0.6
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: parent.width * 0.35
                                        }
                                        // « + » signale un filtre a telecharger,
                                        // la coche un filtre deja present.
                                        Kirigami.Icon {
                                            source: model.installed ? "checkmark" : "list-add"
                                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                        }
                                    }
                                }
                            }
                        }
                    }

                    PlasmaComponents.ToolButton {
                        id: clearButton
                        icon.name: "edit-clear"
                        enabled: !root.busy && root.activeHeadphone !== "none"
                        display: PlasmaComponents.AbstractButton.IconOnly
                        onClicked: root.switchHeadphone("none")
                        PlasmaComponents.ToolTip.text: i18n("Remove the correction")
                        PlasmaComponents.ToolTip.visible: hovered
                        PlasmaComponents.ToolTip.delay: 700
                    }
                }

                // Reglage de reverberation : raccourcit la queue du profil actif
                // sans changer de profil. Absent si le generateur n'est pas
                // compile — le reste fonctionne sans lui.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    visible: root.envelopeAvailable

                    PlasmaComponents.Label {
                        text: i18n("Damping:")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.8
                    }
                    PlasmaComponents.Slider {
                        id: envelopeSlider
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        stepSize: 5
                        enabled: !root.busy
                        value: root.envelope
                        onPressedChanged: if (!pressed) root.setEnvelope(value)
                    }
                    PlasmaComponents.Label {
                        text: i18n("%1 %", Math.round(envelopeSlider.value))
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
        }

        contentItem: PlasmaComponents.ScrollView {
            ListView {
                model: profileModel
                clip: true
                currentIndex: -1

                section.property: "usage"
                section.delegate: Kirigami.ListSectionHeader {
                    width: ListView.view.width
                    text: section === "game"   ? i18n("Gaming — dry and precise")
                        : section === "film"   ? i18n("Film — spacious")
                        : section === "custom" ? i18n("Yours — not measured")
                        :                        i18n("Avoid")
                }

                delegate: PlasmaComponents.ItemDelegate {
                    width: ListView.view.width
                    enabled: !root.busy
                    highlighted: model.isActive
                    onClicked: root.switchProfile(model.name)

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            source: model.isActive ? "checkmark" : ""
                            visible: model.isActive
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }

                        PlasmaComponents.Label {
                            text: model.name
                            font.bold: model.isActive
                            elide: Text.ElideRight
                        }

                        PlasmaComponents.Label {
                            // Le script emet l'anglais canonique ; la traduction
                            // se fait ici, via le catalogue de l'applet.
                            text: i18n(model.note)
                            font: Kirigami.Theme.smallFont
                            opacity: 0.65
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignLeft
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.smallSpacing
                        }

                        // La lateralisation est le critere decisif : on la met en avant,
                        // en rouge quand elle est trop faible pour placer quoi que ce soit.
                        PlasmaComponents.Label {
                            visible: model.measured
                            text: i18n("+%1 dB", model.lat)
                            font: Kirigami.Theme.smallFont
                            color: model.lat < 3 ? Kirigami.Theme.negativeTextColor
                                 : model.lat >= 10 ? Kirigami.Theme.positiveTextColor
                                 : Kirigami.Theme.textColor
                        }
                        PlasmaComponents.Label {
                            visible: model.measured
                            text: i18n("%1 ms", model.reverb)
                            font: Kirigami.Theme.smallFont
                            opacity: 0.6
                        }
                    }

                }
            }
        }
    }
}

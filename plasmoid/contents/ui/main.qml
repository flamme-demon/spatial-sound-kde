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

    property string profilActuel: "…"
    property bool sinkActif: false
    property bool occupe: false
    property string casqueActif: "aucune"
    property int enveloppe: 0
    property bool enveloppeDispo: false
    property string indiceRecherche: ""

    // En deca de ce seuil, une recherche renverrait des centaines d'entrees sans
    // interet et lancerait un processus a chaque frappe.
    readonly property int minCaracteres: 3
    // Au-dela, on fait defiler plutot que d'agrandir : la fenetre du plasmoide
    // est deja juste en hauteur.
    readonly property int maxLignesVisibles: 8

    Plasma5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []

        property var rappels: ({})

        function lancer(commande, rappel) {
            const cle = "sh -c " + "'" + bin + " " + commande + "'";
            rappels[cle] = rappel;
            connectSource(cle);
        }

        onNewData: (source, data) => {
            const rappel = rappels[source];
            delete rappels[source];
            disconnectSource(source);
            if (rappel) {
                rappel(("" + data["stdout"]).trim(), data["exit code"]);
            }
        }
    }

    ListModel { id: modeleProfils }
    ListModel { id: modeleCasques }
    ListModel { id: modeleRecherche }

    function rafraichir() {
        shell.lancer("--data", function (sortie) {
            modeleProfils.clear();
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 6) continue;
                // Un profil ajoute par l'utilisateur n'a pas ete mesure :
                // ses colonnes sont vides et les pastilles restent masquees,
                // plutot que d'afficher des valeurs inventees.
                modeleProfils.append({
                    nom: c[0], usage: c[1],
                    mesure: c[2] !== "",
                    lat: c[2] === "" ? 0 : parseInt(c[2]),
                    reverb: c[3] === "" ? 0 : parseInt(c[3]),
                    note: c[4], estActif: c[5] === "1"
                });
                if (c[5] === "1") root.profilActuel = c[0];
            }
        });
        shell.lancer("--status", function (sortie, code) {
            root.sinkActif = (code === 0);
        });
        shell.lancer("--enveloppe-dispo", function (sortie) {
            root.enveloppeDispo = (sortie.trim() === "1");
        });
        shell.lancer("--enveloppe-actuelle", function (sortie) {
            const v = parseInt(sortie.trim());
            if (!isNaN(v)) root.enveloppe = v;
        });
        shell.lancer("--casque-data", function (sortie) {
            modeleCasques.clear();
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 2) continue;
                if (c[1] === "1") root.casqueActif = c[0];
                modeleCasques.append({ nom: c[0] });
            }
        });
        // Met à jour l'état de référence pour le polling : évite un
        // rafraîchissement redondant au cycle suivant.
        shell.lancer("--sync", function (sortie) {
            root.dernierEtat = sortie;
        });
    }

    // Champ vide : on montre ce qui est deja telecharge. Des qu'on tape, on
    // interroge l'index complet des 8850 casques mesures. Un seul champ couvre
    // donc les deux usages, sans occuper de hauteur supplementaire.
    function rechercherCasques(motif) {
        if (motif.indexOf('"') >= 0 || motif.indexOf("'") >= 0) return;
        if (motif.length > 0 && motif.length < minCaracteres) {
            modeleRecherche.clear();
            root.indiceRecherche = i18np("Type at least %1 character",
                                         "Type at least %1 characters", minCaracteres);
            return;
        }
        root.indiceRecherche = "";
        if (motif.length === 0) {
            modeleRecherche.clear();
            for (let i = 0; i < modeleCasques.count; i++) {
                modeleRecherche.append({
                    nom: modeleCasques.get(i).nom, source: "", installe: true
                });
            }
            return;
        }
        shell.lancer('--casque-chercher-data "' + motif + '"', function (sortie) {
            modeleRecherche.clear();
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 3) continue;
                modeleRecherche.append({
                    nom: c[0], source: c[1], installe: c[2] === "1"
                });
            }
        });
    }

    // Applique a la relache seulement : chaque valeur regenere le profil et
    // recharge la chaine, ce qui serait absurde a chaque pixel du curseur.
    function reglerEnveloppe(v) {
        if (occupe) return;
        occupe = true;
        shell.lancer("--enveloppe " + Math.round(v), function () {
            occupe = false;
            rafraichir();
        });
    }

    function basculerCasque(nom) {
        if (occupe) return;
        // Un nom porteur de guillemets casserait la commande passee au shell.
        if (nom.indexOf('"') >= 0 || nom.indexOf("'") >= 0) return;
        occupe = true;
        const cmd = (nom === "aucune") ? "--casque-aucune" : '--casque "' + nom + '"';
        shell.lancer(cmd, function () {
            occupe = false;
            rafraichir();
        });
    }

    function basculer(nom) {
        if (occupe || nom === profilActuel) return;
        occupe = true;
        // Le changement ne recharge que l'instance dediee : ~0.15 s, sans
        // toucher au serveur audio principal ni aux autres flux.
        shell.lancer(nom, function () {
            occupe = false;
            rafraichir();
        });
    }

    Component.onCompleted: rafraichir()

    // Polling rapide (500 ms) : --sync renvoie une chaîne compacte
    // (profil<TAB>enveloppe<TAB>casque) qu'on compare à l'état précédent.
    // On ne rafraîchit le modèle complet que si quelque chose a changé.
    property string dernierEtat: ""

    Timer {
        interval: 500; running: true; repeat: true
        onTriggered: {
            if (root.occupe) return
            shell.lancer("--sync", function (sortie) {
                if (sortie !== root.dernierEtat) {
                    root.dernierEtat = sortie
                    root.rafraichir()
                }
            })
        }
    }

    // Icone deposee par install.sh dans le theme hicolor de l'utilisateur.
    // On la designe par son NOM, pas par un chemin : c'est ce qu'attendent le
    // navigateur de widgets et le moteur d'icones, et c'est ce qui declenche
    // la recoloration selon le theme clair ou sombre.
    readonly property string icone: "org.spatialsound.kde"
    Plasmoid.icon: icone
    toolTipMainText: i18n("Spatial Sound")
    toolTipSubText: sinkActif
        ? i18n("Profile: %1", profilActuel)
        : i18n("Virtual sink inactive")

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.fill: parent
            source: root.icone
            isMask: true          // teinte par la couleur de texte du panneau
            opacity: root.sinkActif ? 1.0 : 0.5
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
                        text: root.sinkActif ? root.profilActuel : i18n("Inactive")
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    PlasmaComponents.Label {
                        text: root.sinkActif
                            ? i18n("7.1 headphone surround")
                            : i18n("Run install.sh")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                PlasmaComponents.BusyIndicator {
                    running: root.occupe
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
                        id: champCasque
                        Layout.fillWidth: true
                        enabled: !root.occupe
                        // La correction active s'affiche en texte plein, pas en
                        // texte de substitution : celui-ci est gris pale et se lit
                        // comme un champ vide, ce qui masquait l'etat courant.
                        placeholderText: i18n("search a headphone…")

                        function refleterEtat() {
                            text = root.casqueActif === "aucune" ? "" : root.casqueActif;
                        }
                        Component.onCompleted: refleterEtat()
                        Connections {
                            target: root
                            function onCasqueActifChanged() {
                                if (!champCasque.activeFocus) champCasque.refleterEtat();
                            }
                        }

                        // La recherche part sur pause de frappe : sans cela chaque
                        // caractere lancerait un processus.
                        Timer {
                            id: attente
                            interval: 250
                            onTriggered: root.rechercherCasques(champCasque.text)
                        }
                        onTextChanged: attente.restart()
                        onActiveFocusChanged: {
                            if (activeFocus) {
                                // Le nom affiche est selectionne : taper le remplace
                                // au lieu de s'y ajouter.
                                selectAll();
                                root.rechercherCasques("");
                                listeCasques.open();
                            } else {
                                refleterEtat();
                            }
                        }

                        QQC.Popup {
                            id: listeCasques
                            y: -height - Kirigami.Units.smallSpacing
                            width: champCasque.width
                            // Les resultats flottent au-dessus du champ : ils ne
                            // prennent aucune hauteur dans la mise en page, qui est
                            // deja juste.
                            readonly property real hauteurLigne:
                                Math.max(1, vueCasques.count) > 0 && vueCasques.contentHeight > 0
                                    ? vueCasques.contentHeight / Math.max(1, vueCasques.count)
                                    : Kirigami.Units.gridUnit * 2
                            height: root.indiceRecherche !== ""
                                ? Kirigami.Units.gridUnit * 2
                                : Math.min(hauteurLigne * root.maxLignesVisibles,
                                           vueCasques.contentHeight) + 2
                            padding: 1
                            visible: champCasque.activeFocus
                                     && (modeleRecherche.count > 0 || root.indiceRecherche !== "")

                            PlasmaComponents.Label {
                                anchors.centerIn: parent
                                width: parent.width - Kirigami.Units.largeSpacing
                                visible: root.indiceRecherche !== ""
                                text: root.indiceRecherche
                                font: Kirigami.Theme.smallFont
                                opacity: 0.7
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }

                            contentItem: ListView {
                                id: vueCasques
                                clip: true
                                visible: root.indiceRecherche === ""
                                model: modeleRecherche
                                boundsBehavior: Flickable.StopAtBounds
                                QQC.ScrollBar.vertical: QQC.ScrollBar {
                                    policy: QQC.ScrollBar.AsNeeded
                                }
                                delegate: PlasmaComponents.ItemDelegate {
                                    width: ListView.view.width
                                    onClicked: {
                                        root.basculerCasque(model.nom);
                                        // Pas de vidage : la perte du focus remet
                                        // le champ sur la correction desormais active.
                                        champCasque.focus = false;
                                    }
                                    contentItem: RowLayout {
                                        spacing: Kirigami.Units.smallSpacing
                                        PlasmaComponents.Label {
                                            text: model.nom
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
                                            source: model.installe ? "checkmark" : "list-add"
                                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                        }
                                    }
                                }
                            }
                        }
                    }

                    PlasmaComponents.ToolButton {
                        id: boutonEffacer
                        icon.name: "edit-clear"
                        enabled: !root.occupe && root.casqueActif !== "aucune"
                        display: PlasmaComponents.AbstractButton.IconOnly
                        onClicked: root.basculerCasque("aucune")
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
                    visible: root.enveloppeDispo

                    PlasmaComponents.Label {
                        text: i18n("Damping:")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.8
                    }
                    PlasmaComponents.Slider {
                        id: curseurEnv
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        stepSize: 5
                        enabled: !root.occupe
                        value: root.enveloppe
                        onPressedChanged: if (!pressed) root.reglerEnveloppe(value)
                    }
                    PlasmaComponents.Label {
                        text: i18n("%1 %", Math.round(curseurEnv.value))
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
                model: modeleProfils
                clip: true
                currentIndex: -1

                section.property: "usage"
                section.delegate: Kirigami.ListSectionHeader {
                    width: ListView.view.width
                    text: section === "jeu"    ? i18n("Gaming — dry and precise")
                        : section === "film"   ? i18n("Film — spacious")
                        : section === "perso"  ? i18n("Yours — not measured")
                        :                        i18n("Avoid")
                }

                delegate: PlasmaComponents.ItemDelegate {
                    width: ListView.view.width
                    enabled: !root.occupe
                    highlighted: model.estActif
                    onClicked: root.basculer(model.nom)

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            source: model.estActif ? "checkmark" : ""
                            visible: model.estActif
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }

                        PlasmaComponents.Label {
                            text: model.nom
                            font.bold: model.estActif
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
                            visible: model.mesure
                            text: i18n("+%1 dB", model.lat)
                            font: Kirigami.Theme.smallFont
                            color: model.lat < 3 ? Kirigami.Theme.negativeTextColor
                                 : model.lat >= 10 ? Kirigami.Theme.positiveTextColor
                                 : Kirigami.Theme.textColor
                        }
                        PlasmaComponents.Label {
                            visible: model.mesure
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

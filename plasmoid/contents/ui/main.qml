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
    property int casqueIndex: 0

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

    function rafraichir() {
        shell.lancer("--data", function (sortie) {
            modeleProfils.clear();
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 6) continue;
                modeleProfils.append({
                    nom: c[0], usage: c[1],
                    lat: parseInt(c[2]), reverb: parseInt(c[3]),
                    note: c[4], estActif: c[5] === "1"
                });
                if (c[5] === "1") root.profilActuel = c[0];
            }
        });
        shell.lancer("--status", function (sortie, code) {
            root.sinkActif = (code === 0);
        });
        shell.lancer("--casque-data", function (sortie) {
            modeleCasques.clear();
            let actif = 0;
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 2) continue;
                if (c[1] === "1") actif = modeleCasques.count;
                modeleCasques.append({ nom: c[0] });
            }
            root.casqueIndex = actif;
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

    Timer {
        interval: 30000; running: true; repeat: true
        onTriggered: if (!root.occupe) root.rafraichir()
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
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30

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
                    PlasmaComponents.ComboBox {
                        Layout.fillWidth: true
                        model: modeleCasques
                        textRole: "nom"
                        enabled: !root.occupe && modeleCasques.count > 1
                        currentIndex: root.casqueIndex
                        onActivated: (i) => root.basculerCasque(modeleCasques.get(i).nom)
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
                            text: i18n("+%1 dB", model.lat)
                            font: Kirigami.Theme.smallFont
                            color: model.lat < 3 ? Kirigami.Theme.negativeTextColor
                                 : model.lat >= 10 ? Kirigami.Theme.positiveTextColor
                                 : Kirigami.Theme.textColor
                        }
                        PlasmaComponents.Label {
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

# Session 3 — Milady-Verschwörung + La Rochelle
# Quelle: Dumas, Les trois mousquetaires (1844), Kapitel 30-47 (gemeinfrei).
defmodule MusketiereGenerator.S3 do
  def beats do
    [
      %{
        title: "Aufbruch nach La Rochelle",
        dm:
          "Vier Uhr morgens. Die vier reiten mit der königlichen Eskorte gen Süden. Belagerung von La Rochelle — die letzte große Hugenotten-Festung Frankreichs. Cardinal Richelieu hat persönlich die Belagerung geplant. Sieben Tage Reisen vor euch.",
        core: [
          {"D'Artagnan", "Wir reiten mit etwa vierzig Musketieren plus zweihundert Garde-Soldaten. Tréville selbst kommt mit."},
          {"Athos", "La Rochelle — Hugenotten-Stadt seit zwei Jahrhunderten. Schwer befestigt. Hafenstadt — Versorgung über See."},
          {"Aramis", "Buckingham wird ihnen helfen — von England aus. Schiffe sollen die Versorgung halten."},
          {"Porthos", "Cardinal Richelieu will deshalb einen Damm bauen — quer durch die Hafenmündung. Damit die englischen Schiffe nicht reinkommen."},
          {"D'Artagnan", "Klug."},
          {"Athos", "Aber teuer. Tausende von Soldaten. Monate von Arbeit."},
          {"Aramis", "Und wir vier — was tun wir?"},
          {"SL", "Tréville hat euch zur 'Beweglichen Reserve' eingeteilt. Ihr werdet patrouillieren, kämpfen, wenn nötig. Aber ihr seid auch frei, eigene Erkundungen zu machen."},
          {"D'Artagnan", "Frei. Das gefällt mir."}
        ]
      },
      %{
        title: "Erste Nacht im Lager",
        dm:
          "Erster Reisetag. Lager nördlich von Tours. Die Musketier-Zelte sind aufgebaut. Cardinal Richelieu reitet in einer eigenen Kutsche — er ist da, aber separat. Macht eine Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Sechzehn."},
          {"SL", "Du siehst — eine Frau steigt aus einer Kutsche, die neben Richelieus parkt. Blond, blau-grau-äugig, sehr schön. Du erkennst sie."},
          {"D'Artagnan", "Die Frau aus Meung. Die mit dem Lilien-Brandzeichen."},
          {"SL", "Genau. Milady de Winter — die Cardinal-Spionin, von der Tréville euch gewarnt hat."},
          {"Athos", "Wahrnehmung — ich schaue auch."},
          {"Athos", "Mit Vorteil. Sechsundzwanzig."},
          {"SL", "Athos — du siehst sie. Du weißt sofort: das ist Anne de Bueil. Deine vermeintlich tote Frau. Lebendig. In Diensten des Cardinals. Du wirst weiß im Gesicht."},
          {"Athos", "Ich verlasse das Lager — gehe in den Wald. Allein. Brüder, frage mich nicht heute."},
          {"D'Artagnan", "Athos —"},
          {"Athos", "Heute nicht."}
        ]
      },
      %{
        title: "Milady macht D'Artagnan einen Avance",
        dm:
          "Am nächsten Morgen. Die Karawane bricht auf. Milady fährt in ihrer Kutsche. Sie schaut aus dem Fenster — direkt zu D'Artagnan. Sie lächelt — sehr knapp, einladend. Macht eine Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Achtzehn."},
          {"SL", "Sie lächelt dich an — als hätte sie dich erkannt. Du erinnerst dich — sie war in Meung. Aber damals war sie unauffällig. Jetzt ist sie sichtbar."},
          {"D'Artagnan", "Ich nähere mich der Kutsche."},
          {"SL", "Milady öffnet die Tür. 'Junger Herr — ein Stück mit mir reiten?'"},
          {"D'Artagnan", "Ich nehme das Angebot. Steige in die Kutsche."},
          {"SL", "Milady: 'Mein Name ist Milady de Winter. Ich diene — verschiedenen Ladys. Was ist euer Name?'"},
          {"D'Artagnan", "D'Artagnan. Garde-Soldat von M. des Essarts."},
          {"SL", "Milady: 'D'Artagnan. Ein gascognischer Name. Ihr seid jung. Sehr jung.'"},
          {"D'Artagnan", "Persuasion-Probe. Ich versuche, geheimnisvoll zu sein."},
          {"D'Artagnan", "Persuasion. Vierzehn — knapp."},
          {"SL", "Milady lächelt nachsichtig. 'Mein Herr — ihr seid charmant aber durchsichtig. Ich werde euch dennoch einladen. Heute Abend, im Lager bei Châtellerault, mein Zelt. Nach Mitternacht.'"},
          {"D'Artagnan", "Ich komme."}
        ]
      },
      %{
        title: "D'Artagnan im Milady-Zelt",
        dm:
          "Mitternacht. D'Artagnan schleicht zu Miladys Zelt — luxuriöser als die anderen, mit Wandbehängen. Sie ist alleine. Sie trinkt Wein.",
        core: [
          {"SL", "Milady: 'D'Artagnan. Setzt euch.'"},
          {"D'Artagnan", "Ich setze mich. Sehr nervös."},
          {"SL", "Sie schenkt dir Wein ein. Macht eine Insight-Probe."},
          {"D'Artagnan", "Insight. Mit Vorteil — ich bin misstrauisch. Erster Wurf: zwölf. Zweiter: neunzehn. Ich nehme neunzehn."},
          {"SL", "Du siehst — sie ist nicht aufrichtig. Sie spielt eine Rolle. Sie will etwas von dir. Wahrscheinlich Informationen über Tréville, Königin Anne, deine Brüder."},
          {"D'Artagnan", "Ich spiele auch eine Rolle — als jung-naiver Gascogner, der ihr glaubt."},
          {"SL", "Milady: 'D'Artagnan — ihr seid sehr — interessant. Erzählt mir mehr. Über die Königin. Über M. de Buckingham, von dem ihr… etwas wisst.'"},
          {"D'Artagnan", "Ich tue, als wüsste ich nichts. 'Eure Hoheit — ich bin nur Garde-Soldat. Ich weiß nichts von Königin oder Buckingham.'"},
          {"SL", "Sie lächelt — sieht durch deine Lüge. Aber sie spielt mit. 'Vielleicht reicht es, wenn ihr… wenn wir uns kennenlernen.'"},
          {"D'Artagnan", "Wir kennen uns."}
        ]
      },
      %{
        title: "D'Artagnan sieht das Brandzeichen",
        dm:
          "Im Spiel der Verführung — du ziehst Milady näher. Ihr Kleid rutscht ein wenig herunter. Macht eine Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Mit Vorteil — ich bin auf der Hut. Erster Wurf: achtzehn. Zweiter: zweiundzwanzig. Ich nehme zweiundzwanzig."},
          {"SL", "Du siehst es — eine Lilien-Brandzeichen auf ihrer linken Schulter. Klar erkennbar."},
          {"D'Artagnan", "Ich weiß — Lilien-Brandzeichen — das ist das Verbrecher-Brandzeichen. Sie ist eine bestrafte Verbrecherin."},
          {"SL", "Milady sieht deinen Blick. Ihre Augen werden eiskalt."},
          {"SL", "Milady: 'Ihr habt es gesehen, junger Herr. Niemand sieht das und überlebt es.'"},
          {"D'Artagnan", "Initiative."},
          {"SL", "Milady greift unter ein Kissen — sie hat einen Dolch dort. Trefferversuch — sechzehn."},
          {"D'Artagnan", "Geschicklichkeits-Save. Mit Inspiration. Erster Wurf: vierzehn. Zweiter: einundzwanzig. Mit Inspiration plus drei: vierundzwanzig. Bestanden."},
          {"SL", "Du weichst aus. Du rennst aus dem Zelt — Milady schreit hinter dir her. 'D'Artagnan — du wirst dafür bezahlen!'"},
          {"D'Artagnan", "Ich renne zurück zum Musketier-Lager. Schnell."}
        ]
      },
      %{
        title: "D'Artagnan erzählt den Brüdern",
        dm:
          "Am Morgen. D'Artagnan erzählt seinen Brüdern. Athos sitzt verschlossen, hört zu.",
        core: [
          {"D'Artagnan", "Milady hat ein Lilien-Brandzeichen auf der linken Schulter. Sie wollte mich töten, als ich es sah."},
          {"Aramis", "Lilien-Brandzeichen? Das ist das Brandzeichen der Verurteilten — sehr alte Strafe. Heute kaum noch in Gebrauch."},
          {"Porthos", "Was hat sie verbrochen?"},
          {"D'Artagnan", "Sie weigerte sich, es zu sagen."},
          {"Athos", "Diebstahl. Diebstahl von Kirchengütern. Oder Mord."},
          {"D'Artagnan", "Du weißt es?"},
          {"Athos", "D'Artagnan. Brüder — ich muss euch etwas erzählen. Ich erzähle es jetzt zum ersten Mal."},
          {"SL", "Athos atmet tief. Beschreibt mir, wie ihr alle reagiert."},
          {"D'Artagnan", "Ich setze mich gegenüber. Bereit zu hören."},
          {"Porthos", "Ich werfe Insight — schon mal vorbeugend. Vierzehn — er ist offen."},
          {"Aramis", "Ich lege meinen Rosenkranz beiseite. Ich höre."}
        ]
      },
      %{
        title: "Athos' Geständnis",
        dm:
          "Athos beginnt. Sehr ruhig. Seine Stimme ist tief.",
        core: [
          {"Athos", "Ich war einmal Comte de la Fère — ein wohlhabender Graf in der Provinz Berry. Mit zwanzig habe ich geheiratet. Anne de Bueil — sechzehn, blond, blau-grau-äugig. Eine reizende Frau. Ich liebte sie sehr."},
          {"Athos", "Ein Jahr später — wir jagten zusammen. Sie fiel vom Pferd, schwer. Ihr Kleid wurde aufgerissen — ich sah auf ihrer linken Schulter ein Lilien-Brandzeichen. Sie war eine verurteilte Verbrecherin. Ohne mein Wissen."},
          {"Athos", "Ich tat, was ein Edelmann tut. Ich hängte sie an einem Baum. Ich dachte, sie wäre tot."},
          {"D'Artagnan", "Du… du hast sie GEHÄNGT?"},
          {"Athos", "Heimlich. Ohne Prozess. Es war eine furchtbare Tat — aber damals dachte ich, es sei meine Pflicht."},
          {"Athos", "Sie war anscheinend nicht tot. Sie hat überlebt. Sie hat einen neuen Namen angenommen — Milady de Winter — und arbeitet jetzt für Cardinal Richelieu."},
          {"Porthos", "Bei den Heiligen."},
          {"Aramis", "Eine Verbrecherin und Ex-Frau eines Comte — die Geschichte ist schwer."},
          {"D'Artagnan", "Athos — sie kennt dich also auch?"},
          {"Athos", "Sie hat mich gestern erkannt. Sie weiß, dass ich lebe. Wir sind jetzt in einem stillen Krieg, sie und ich."}
        ]
      },
      %{
        title: "Ankunft in La Rochelle",
        dm:
          "Eine Woche später. Die königliche Karawane erreicht La Rochelle. Die Stadt liegt am Meer, ihre Mauern sind sechzig Fuß hoch. Im Süden — der Damm im Bau, ein gigantisches Projekt. Im Norden — die königlichen Lager, tausende von Zelten, vierzigtausend Soldaten.",
        core: [
          {"SL", "Tréville: 'Meine Herren — wir sind hier. Eure Aufgabe — patrouillieren, beobachten, Aufklärung. Spätere Befehle direkt von mir.'"},
          {"D'Artagnan", "Wir nehmen unser Zelt — vier zusammen."},
          {"Aramis", "Mehr Raum. Athos kann die Wand haben, Porthos die andere, D'Artagnan und ich Mitte."},
          {"Porthos", "Das ist nicht symmetrisch. Aber Athos schnarcht."},
          {"Athos", "Ich schnarche nicht."},
          {"Porthos", "Du schnarchst sehr."},
          {"SL", "Das Lager ist groß, dreckig. Es regnet die Hälfte der Zeit. Krankheiten — Ruhr, Pocken. Aber die vier sind in der königlichen Kompanie — bessere Zelte, sauberes Wasser."},
          {"D'Artagnan", "Tag eins — wir patrouillieren."}
        ]
      },
      %{
        title: "Patrouille an der Bastion Saint-Gervais",
        dm:
          "Vier Wochen ins Lager. Eine kleine Bastion außerhalb der Hauptmauern — Bastion Saint-Gervais. Sie ist ungebaut, verlassen, früher von Hugenotten benutzt. Tréville schickt die vier, um sie zu erkunden — eventuell als Vorposten für die Sturm-Vorbereitung.",
        core: [
          {"SL", "Tréville: 'Meine Herren — die Bastion Saint-Gervais. Erkundet sie. Aber Vorsicht — sie wird von Hugenotten regelmäßig angegriffen. Möglicherweise heute Morgen.'"},
          {"D'Artagnan", "Wir reiten hin. Vier Stunden vor Sonnenaufgang."},
          {"Athos", "Brüder — eine Idee. Wir gehen zur Bastion, frühstücken dort. Halten sie gegen einen Hugenotten-Sturm. Beweisen uns vor den anderen Musketieren."},
          {"Porthos", "Frühstücken?"},
          {"Athos", "Hähnchen, Brot, Wein. Ein königliches Frühstück."},
          {"Aramis", "Während wir gleichzeitig einen Sturm abhalten."},
          {"D'Artagnan", "Es ist verrückt. Es gefällt mir."},
          {"Athos", "Es ist verrückt. Es wird Legende werden."}
        ]
      },
      %{
        title: "Frühstück auf der Bastion",
        dm:
          "Sonnenaufgang. Vier Musketiere — pardon, drei Musketiere und ein Garde-Soldat — sitzen auf der Bastion Saint-Gervais. Ein kleiner Tisch — Provisorium. Brot, Wein, Hähnchen, Käse. Sie essen seelenruhig. In etwa zweihundert Metern Entfernung — die Hugenotten in der Stadtmauer beobachten.",
        core: [
          {"Athos", "Ich gieße Wein ein. Champagner aus dem königlichen Vorrat — Tréville hat es gestern unverschlossen gelassen."},
          {"Porthos", "Ich nehme zwei Schinkenstücke."},
          {"Aramis", "Latein-Gebet zum Frühstück: 'Pater noster, qui es in caelis…'"},
          {"D'Artagnan", "Aramis — sehr passend."},
          {"SL", "Du hörst — von der Stadtmauer — ein Trompetenstoß. Ein Sturm wird vorbereitet."},
          {"Athos", "Wir machen weiter. Wir frühstücken."},
          {"SL", "Macht alle eine Wahrnehmungs-Probe."},
          {"D'Artagnan", "Wahrnehmung. Achtzehn."},
          {"SL", "Du zählst — etwa zwanzig Hugenotten-Soldaten kommen aus der Stadtmauer. Mit Musketen."},
          {"Porthos", "Zwanzig gegen vier? Akzeptabel."},
          {"Aramis", "Sicut dixit dominus. Wir kämpfen mit Latein und Klinge."}
        ]
      },
      %{
        title: "Erster Hugenotten-Sturm",
        dm:
          "Die Hugenotten nähern sich — vorsichtig, in Schwarmformation. Sie wollen die Bastion einnehmen, weil sie strategisch ist. Initiative.",
        core: [
          {"D'Artagnan", "Initiative. Achtzehn."},
          {"Athos", "Sechzehn."},
          {"Porthos", "Vierzehn."},
          {"Aramis", "Sechzehn."},
          {"SL", "Hugenotten — zwölf."},
          {"D'Artagnan", "Ich greife mit der Muskete an — der schnellste Hugenotte. Trefferversuch mit Vorteil: achtzehn. Schaden: dreizehn."},
          {"SL", "Erster Hugenotte fällt."},
          {"Athos", "Athos-Smite auf den nächsten. Trefferversuch: einundzwanzig. Schaden: einundzwanzig."},
          {"SL", "Zweiter Hugenotte fällt."},
          {"Porthos", "Ich werfe einen Stein. Trefferversuch: sechzehn — Treffer. Schaden: acht."},
          {"SL", "Dritter Hugenotte verwundet."},
          {"Aramis", "Sacred Flame auf Hugenotte vier. Reflex-Save."},
          {"SL", "Hugenotte vier verfehlt — sieben Strahlenschaden."},
          {"SL", "Hugenotten reagieren — Musketen-Salve. Trefferversuche gegen Bastion. Alle Würfen unter siebzehn — Mauer hält."}
        ]
      },
      %{
        title: "Zweite Welle — vierzig Hugenotten",
        dm:
          "Erste Welle abgewehrt. Aber jetzt — eine zweite Welle. Vierzig Hugenotten kommen — mit Sturmleitern. Sie wollen die Mauer überqueren.",
        core: [
          {"SL", "Vierzig Hugenotten. Vier Musketiere. Macht eure Aktionen — jede Runde."},
          {"D'Artagnan", "Reckless Attack mit Muskete. Trefferversuch: einundzwanzig. Schaden: vierzehn."},
          {"Athos", "Mehrfach-Attack — Smites. Drei Treffer. Sechsunddreißig Schaden."},
          {"Porthos", "Maximale Reckless. Vier Treffer. Vierundfünfzig Schaden."},
          {"Aramis", "Spirit Guardians — alle Hugenotten in fünfzehn Fuß. Acht Schaden für jeden."},
          {"SL", "Erste Runde — sieben Hugenotten fallen. Zweite Runde — zehn weitere."},
          {"SL", "Dritte Runde — die Hugenotten zögern. Sie haben fünfzehn Mann verloren. Sie ziehen sich zurück."},
          {"Athos", "Wir lassen sie ziehen."},
          {"D'Artagnan", "Wir frühstücken weiter."}
        ]
      },
      %{
        title: "Dritte Welle — eine Stunde später",
        dm:
          "Eine Stunde frühstücken. Dann — neue Welle. Diesmal sechzig Hugenotten. Sie sind ärgerlich.",
        core: [
          {"Porthos", "Sechzig? Endlich eine Herausforderung."},
          {"D'Artagnan", "Athos — strategischer Vorschlag?"},
          {"Athos", "Wir lassen sie auf die Mauer kommen. Dann von oben — Reckless-Attacken. Sie sind enge gebunden."},
          {"D'Artagnan", "Genial."},
          {"SL", "Die Hugenotten klettern. Erste zehn erreichen die Mauer. Initiative."},
          {"D'Artagnan", "Achtzehn."},
          {"Athos", "Zwanzig."},
          {"Porthos", "Sechzehn."},
          {"Aramis", "Sechzehn."},
          {"D'Artagnan", "Sneak-Attack mit Vorteil. Treffer: vierundzwanzig. Sechzehn Schaden mit Sneak-Bonus."},
          {"Athos", "Smite-Welle. Drei Treffer. Sechsundfünfzig Schaden total."},
          {"Porthos", "Reckless. Drei Treffer. Achtundvierzig Schaden."},
          {"Aramis", "Spirit Guardians erweitert. Zwölf Schaden für je sieben Hugenotten."},
          {"SL", "Sechzehn Hugenotten gefallen in der Welle. Die anderen ziehen sich zurück — verzweifelt."}
        ]
      },
      %{
        title: "Tréville kommt — beeindruckt",
        dm:
          "Vier Stunden nach Sonnenaufgang. Die Bastion-Verteidigung ist Legende. Tréville und zwanzig Musketiere kommen — sie hatten Schüsse gehört, dann nichts. Sie befürchteten das Schlimmste.",
        core: [
          {"SL", "Tréville sieht — vier Musketiere, frühstückend. Um sie herum: zwanzig tote Hugenotten in der Mauer-Umgebung, schätzungsweise dreißig in der Ferne."},
          {"SL", "Tréville: 'Bei den GÖTTERN — was habt ihr getan?'"},
          {"Athos", "Wir haben gefrühstückt. Und nebenbei drei Hugenotten-Wellen abgewehrt."},
          {"SL", "Tréville: 'Drei Wellen? Sechzig Hugenotten?'"},
          {"D'Artagnan", "Etwa. Wir haben nicht gezählt."},
          {"SL", "Tréville lacht — laut. 'Das wird in den Höfen Frankreichs erzählt werden. Vier Musketiere — frühstückend — sechzig Hugenotten besiegt.'"},
          {"Porthos", "Wir hatten noch ein bisschen Wein übrig."},
          {"Aramis", "Sicut dixit dominus — die Klinge folgt dem Gebet."},
          {"SL", "Tréville: 'Meine Herren — der König wird euch ehren. Er kommt morgen ins Lager.'"}
        ]
      },
      %{
        title: "Königliche Audienz",
        dm:
          "Am nächsten Tag. König Louis XIII besucht das Lager. Er kommt persönlich zur Bastion Saint-Gervais — er will die Mauern sehen, wo die vier gefrühstückt haben.",
        core: [
          {"SL", "König Louis XIII: 'D'Artagnan! Athos! Porthos! Aramis! Mein Lieblings-Vier-Männer-Team!'"},
          {"D'Artagnan", "Sire."},
          {"SL", "Louis XIII: 'Was ihr getan habt — sechzig Hugenotten besiegt, mit Frühstück. Das wird in den Liedern erzählt werden.'"},
          {"Athos", "Sire — wir tun unsere Pflicht."},
          {"SL", "Louis XIII: 'Aramis — eure Spiritual-Magie war beeindruckend. Wenn der Cardinal nicht so eifersüchtig auf Macht wäre, würde ich euch zum Hofkleriker ernennen.'"},
          {"Aramis", "Sire — ich diene."},
          {"SL", "Louis XIII zieht D'Artagnan beiseite. 'Junger Mann — ich weiß, was ihr mit der Anhänger-Affäre für meine Frau Anne getan habt. Ich habe es nicht offiziell anerkannt — der Cardinal weiß nicht, dass ich weiß. Aber ich weiß. Danke.'"},
          {"D'Artagnan", "Sire — ich diene."}
        ]
      },
      %{
        title: "Geheimes Treffen — Cardinal und Milady",
        dm:
          "Spätabend. D'Artagnan ist auf Patrouille — er beobachtet das Cardinal-Lager aus der Ferne. Er sieht — eine Frau geht in Richelieu's Zelt. Macht eine Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Mit Vorteil. Erster Wurf: sechzehn. Zweiter: einundzwanzig. Ich nehme einundzwanzig."},
          {"SL", "Du siehst — Milady de Winter. Sie geht in Richelieus Zelt. Du schleichst näher — du willst lauschen."},
          {"D'Artagnan", "Heimlichkeit. Mit Vorteil — Swashbuckler-Vorteil. Erster Wurf: achtzehn. Zweiter: zweiundzwanzig. Ich nehme zweiundzwanzig."},
          {"SL", "Du bist hinter dem Zelt. Du kannst durch eine Lücke lauschen."},
          {"SL", "Richelieu: 'Milady — drei Aufträge. Ersten: nach England reisen. Buckingham ermorden. Wenn er stirbt, fällt die englische Flottenunterstützung weg, und La Rochelle fällt in zwei Monaten.'"},
          {"SL", "Milady: 'Ich werde es tun.'"},
          {"SL", "Richelieu: 'Zweiten: D'Artagnan eliminieren. Er ist zu mutig, zu loyal zur Königin. Eine Gefahr.'"},
          {"SL", "Milady: 'Mit Vergnügen. Ich habe persönlichen Grund.'"},
          {"SL", "Richelieu: 'Dritten: ich habe euch eine Information. Constance Bonacieux — die Hofdame, die ihr für die Königin-Anhänger-Affäre gebraucht hat — wir haben sie im Karmeliten-Konvent von Béthune versteckt. Wenn ihr in Frankreich seid, kümmert euch um sie.'"},
          {"D'Artagnan", "Bei den Heiligen."}
        ]
      },
      %{
        title: "D'Artagnan-Plan",
        dm:
          "D'Artagnan schleicht zurück zum Musketier-Lager. Er informiert die Brüder.",
        core: [
          {"D'Artagnan", "Brüder — gefährliche Nachrichten."},
          {"D'Artagnan", "Erstens: Milady reist nach England. Sie soll Buckingham ermorden."},
          {"D'Artagnan", "Zweitens: Milady soll mich ermorden — auf Cardinal-Befehl."},
          {"D'Artagnan", "Drittens: Constance ist im Karmeliten-Konvent von Béthune. Aber Milady weiß das. Sie wird Constance auch ermorden — wenn sie zurückkommt."},
          {"Athos", "Bei den Heiligen."},
          {"Porthos", "Wir müssen Buckingham warnen."},
          {"Aramis", "Wir müssen Constance retten — bevor Milady ankommt."},
          {"Athos", "Aber wir können nicht. Tréville hat uns verboten, das Lager zu verlassen — die Belagerung erfordert uns."},
          {"D'Artagnan", "Was tun wir?"},
          {"Athos", "Wir schreiben. Briefe. An Buckingham — an Lord de Winter, Miladys Schwager, der sie schon aus England-Aufenthalt kennt und nicht mag."},
          {"Aramis", "Lord de Winter. Wer ist Lord de Winter?"},
          {"Athos", "Miladys verstorbener Mannes Bruder. Er hat sie in England eingesperrt — sie hat ihn finanziell geschädigt — er weiß, dass sie eine Verbrecherin ist."},
          {"D'Artagnan", "Wir schreiben."}
        ]
      },
      %{
        title: "Die Briefe werden geschrieben",
        dm:
          "Athos diktiert. Aramis schreibt — er hat die schönste Schrift. Drei Briefe.",
        core: [
          {"Aramis", "Brief eins — an Lord de Winter, London. 'Mein Lord — Milady ist auf dem Weg nach London. Auftrag von Cardinal Richelieu: Mord am Herzog von Buckingham. Bitte verhaftet sie sofort bei Ankunft.'"},
          {"Aramis", "Brief zwei — an Buckingham. 'Herzog — eine Assassine kommt. Milady de Winter, blond, blau-grau-äugig, Lilien-Brandzeichen linke Schulter. Hütet euch.'"},
          {"Aramis", "Brief drei — an die Äbtissin im Karmeliten-Konvent von Béthune. 'Verehrte Mutter — Constance Bonacieux, eure Schutzbefohlene, ist in Gefahr. Eine bestimmte Milady de Winter ist auf dem Weg, um sie zu ermorden. Hütet sie sehr gut.'"},
          {"D'Artagnan", "Wer kann diese Briefe übermitteln?"},
          {"Athos", "Planchet — mein Diener. Er ist vertrauenswürdig. Er wird mit dem Schiff fahren — zu Lord de Winter und Buckingham."},
          {"Aramis", "Für den Béthune-Brief — Bazin, mein Diener. Er ist langsam, aber zuverlässig."},
          {"D'Artagnan", "Wir versiegeln. Jetzt."}
        ]
      },
      %{
        title: "Briefe gehen raus",
        dm:
          "Planchet bricht sofort auf — Pferd, dann Schiff. Bazin bricht am Morgen auf — Pferd, lange Reise nach Béthune.",
        core: [
          {"SL", "Planchet: 'Mein Herr — ich werde nicht schlafen, nicht essen, nicht trinken, bis ich London erreiche.'"},
          {"D'Artagnan", "Planchet — du bist ein guter Mann."},
          {"SL", "Planchet bricht auf. In drei Tagen wird er in London sein — wenn er nicht verschwindet."},
          {"SL", "Bazin verlässt am Morgen. Mit dem Brief im Wams. Drei Wochen Reise nach Béthune — das ist seine Schätzung."},
          {"Aramis", "Drei Wochen ist zu langsam. Milady ist schneller."},
          {"Athos", "Wir reiten ihr nach. Sobald die Belagerung uns freilässt."},
          {"D'Artagnan", "Wann ist die Belagerung zu Ende?"},
          {"Athos", "Cardinal Richelieu sagt — drei Monate."},
          {"D'Artagnan", "Drei MONATE? Bis dahin — sind alle tot."},
          {"Athos", "Wir warten, was die Briefe bewirken."}
        ]
      },
      %{
        title: "Cliffhanger — Hoffnung und Sorge",
        dm:
          "Letzte Nacht der Session. Vier Musketiere sitzen am Lagerfeuer.",
        core: [
          {"Athos", "Wein für alle."},
          {"D'Artagnan", "Athos — du trinkst zu viel."},
          {"Athos", "D'Artagnan — du redest zu viel."},
          {"Porthos", "Wir streiten nicht. Heute Abend — wir trinken."},
          {"Aramis", "Auf Constance."},
          {"D'Artagnan", "Auf Constance."},
          {"Athos", "Auf den Tod der Milady."},
          {"D'Artagnan", "Auf Athos' Rache."},
          {"Aramis", "Auf Buckingham — möge er warnen seine Wachen."},
          {"Porthos", "Auf den Cardinal — möge er sich verschlucken."},
          {"SL", "Vier Musketiere trinken bis spät in die Nacht. Cliffhanger — Briefe sind unterwegs, Milady ist unterwegs, alles hängt am Glück."},
          {"SL", "Session-Ende. XP — 1400. Inspiration für Athos — sein Geständnis war schmerzlich. Inspiration für D'Artagnan — die Lauschattacke war Gold."},
          {"D'Artagnan", "Inspiration genommen. Ich brauche sie für nächste Session."},
          {"Athos", "Auch genommen. Ich werde sie für Milady brauchen."}
        ]
      }
    ]
  end
end

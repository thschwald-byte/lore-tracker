# Session 2 — Anhänger der Königin
# Quelle: Dumas, Les trois mousquetaires (1844), Kapitel 10-22 (gemeinfrei).
defmodule MusketiereGenerator.S2 do
  def beats do
    [
      %{
        title: "Recap + Constance bittet um Hilfe",
        dm:
          "Eine Woche nach Session-Ende. Madame Bonacieux klopft an D'Artagnans Tür — spät abends, ihr Mann ist verreist. Sie ist verstört, atmet schwer. Sie hat eine schreckliche Mission und braucht jemanden, dem sie vertrauen kann.",
        core: [
          {"D'Artagnan", "Ich öffne die Tür. Constance fällt fast hinein."},
          {"SL", "Constance: 'Mein Herr — D'Artagnan — ich brauche euch. Die Königin braucht euch. Ich darf eigentlich nicht reden, aber — ihr seid Musketier, ihr habt Cardinal-Wachen besiegt — ich habe niemanden sonst.'"},
          {"D'Artagnan", "Setz dich, Constance. Sprich."},
          {"SL", "Constance: 'Cardinal Richelieu will die Königin Anne stürzen. Er hat dem König eingeredet, sie habe ein Anhänger-Geschenk an den Herzog von Buckingham gegeben. Zwölf Diamanten-Anhänger, einst ein Geschenk des Königs. Anne hat sie tatsächlich Buckingham geschenkt — bei einer geheimen Begegnung. Wenn der König Anne fragt: 'Trage die Anhänger nächste Woche zum Ball' — und sie hat sie nicht — Skandal. Vielleicht Annulment. Vielleicht Schlimmeres.'"},
          {"D'Artagnan", "Und was kann ich tun?"},
          {"SL", "Constance: 'Nach London reiten. Die Anhänger zurückholen. Zwölf Tage Zeit. Ich habe das Geld — fünfhundert Pistolen, von der Königin selbst.'"},
          {"D'Artagnan", "Constance — ich reite. Mit meinen Brüdern."},
          {"SL", "Constance küsst dich auf die Wange. 'D'Artagnan — wenn ihr zurückkommt — vielleicht — vielleicht — ' Sie weint."}
        ]
      },
      %{
        title: "Geheime Audienz bei der Königin",
        dm:
          "Zwei Tage später. D'Artagnan wird in den Louvre geführt — durch einen geheimen Weg. Eine Treppe nach oben, ein Korridor, eine kleine Tür. Königin Anne d'Autriche steht in einem kleinen Salon. Sie ist sechsundzwanzig — blond, blau-grau-äugig, in einem dunkelblauen Kleid. Sie ist nervös aber königlich.",
        core: [
          {"SL", "Königin Anne: 'D'Artagnan. Capitain Tréville hat mir von euch erzählt.'"},
          {"D'Artagnan", "Königliche Hoheit. Ich verbeuge mich tief."},
          {"SL", "Königin Anne: 'D'Artagnan — die Anhänger. Es sind zwölf Diamant-Anhänger, einer für jeden Apostel symbolisch. Mein Mann, der König, gab sie mir zur Hochzeit. Ich habe — in einem Moment der Schwäche — sie an einen Freund aus England geschenkt. Der Cardinal hat irgendwie erfahren. Er hat dem König geraten, mich zu bitten, sie zum Ball zu tragen. Wenn ich sie nicht habe — ihr versteht.'"},
          {"D'Artagnan", "Ich verstehe. Ich werde sie holen."},
          {"SL", "Königin Anne: 'Mein Freund in England ist der Herzog von Buckingham. Ihr werdet ihn finden im Palast Whitehall. Er weiß, dass ein Bote kommt. Er wird mich helfen.'"},
          {"D'Artagnan", "Ich reise mit meinen Brüdern — drei Musketieren. Wir werden in acht Tagen zurück sein."},
          {"SL", "Königin Anne: 'Acht Tage? D'Artagnan — Paris zu London ist normalerweise neun. Und neun zurück.'"},
          {"D'Artagnan", "Wir reiten Tag und Nacht. Vertraut mir."},
          {"SL", "Anne nimmt einen kleinen Ring von ihrer Hand. 'Das ist mein Saphir-Ring. Wenn ihr in Schwierigkeiten geratet — zeigt ihn. Er ist ein königliches Zeichen. Und nehmt diese Münzen.'"},
          {"D'Artagnan", "Ich nehme den Ring und die Münzen. Ich verbeuge mich."},
          {"Athos", "Wir hören das später von D'Artagnan. Wir wussten nichts von der direkten Audienz."}
        ]
      },
      %{
        title: "Plan-Schmiede",
        dm:
          "Zurück bei den drei Musketieren. D'Artagnan erklärt — alles. Sie sitzen am Lagerfeuer-Imitat im Kamin von Athos' kleinem Quartier.",
        core: [
          {"D'Artagnan", "Brüder — die Königin braucht ihre Anhänger zurück. Acht Tage Zeit. Wir reiten morgen früh."},
          {"Athos", "Acht Tage? Paris-London-Paris? Das ist verrückt — selbst mit Postkutsche."},
          {"Aramis", "Wir reiten zu Pferde, nicht mit Kutsche. Tag und Nacht."},
          {"Porthos", "Was ist die Bedrohung? Cardinal-Wachen?"},
          {"D'Artagnan", "Sicher. Der Cardinal weiß bereits, dass wir reisen — oder erfährt es bald. Er wird Hinterhalte vorbereiten."},
          {"Athos", "Wenn er Hinterhalte vorbereitet, müssen wir die Möglichkeit einkalkulieren, dass einer von uns fällt. Oder mehrere."},
          {"D'Artagnan", "Strategie: einer reitet voraus. Die anderen folgen — verteidigen, wenn Hinterhalte kommen. Wer fällt, fällt. Wer übrigbleibt, reitet weiter."},
          {"Porthos", "Sehr gascognisch. Ich mag es."},
          {"Aramis", "Sicut dixit dominus — wir leben oder wir sterben, einer für alle."},
          {"Athos", "Einer für alle. Alle für einen. Wir starten morgen früh, vier Uhr."}
        ]
      },
      %{
        title: "Abreise — vier reiten gen Norden",
        dm:
          "Vier Uhr morgens. Vier Reiter — Athos, Porthos, Aramis, D'Artagnan — verlassen Paris durch das Saint-Denis-Tor. Es ist kalt, der Boden gefroren. Sie reiten in dichtem Galopp. Macht eine Konstitutionsprobe — Reiten ohne Pause für 12 Stunden.",
        core: [
          {"D'Artagnan", "Konstitution. Achtzehn."},
          {"Athos", "Konstitution. Fünfzehn."},
          {"Porthos", "Konstitution. Sechzehn."},
          {"Aramis", "Konstitution. Vierzehn."},
          {"SL", "Alle bestanden. Ihr reitet zwölf Stunden ohne Pause, erreicht das Dorf Chantilly bei Sonnenuntergang. Eine Herberge — 'Le Cygne d'Or'. Ihr braucht Pferdewechsel."},
          {"D'Artagnan", "Wir gehen rein für eine schnelle Mahlzeit."},
          {"SL", "Im Wirtshaus — ein Fremder sitzt am Kamin. Er lacht laut — über etwas. Macht eine Wahrnehmungs-Probe."},
          {"Porthos", "Wahrnehmung. Sechzehn."},
          {"SL", "Der Fremde — ein dicker Mann, rot im Gesicht — lacht über Porthos. 'Schaut diesen Aufschneider — viel Kleidung, wenig Hirn!'"},
          {"Porthos", "Ich — ich höre das. Ich gehe direkt zu ihm hin."}
        ]
      },
      %{
        title: "Porthos bleibt zurück",
        dm:
          "Der Fremde steht auf. Er ist nicht klein — fast so groß wie Porthos. Er trägt einen Brustpanzer — kein normaler Reisender. Initiative.",
        core: [
          {"Porthos", "Initiative. Vierzehn."},
          {"SL", "Der Fremde: zwanzig. Er ist ein Hauptmann der Garde von Mortagne — du erfährst seinen Namen erst später. Aber er ist ein erfahrener Schwertkämpfer."},
          {"Porthos", "Ich greife trotzdem. Reckless Attack."},
          {"SL", "Trefferversuch."},
          {"Porthos", "Erster Wurf mit Vorteil: einundzwanzig. Zweiter: sechzehn. Ich nehme einundzwanzig — Treffer."},
          {"SL", "Schaden — Größe-Waffe."},
          {"Porthos", "Acht Schaden."},
          {"SL", "Der Hauptmann taumelt — aber er ist nicht zu Boden. Er attackiert zurück — Treffer auf neunzehn. Vierzehn Schaden."},
          {"D'Artagnan", "Porthos — wir können nicht alle in einem Duell verheddert sein. Athos, Aramis und ich — wir reiten weiter."},
          {"Porthos", "Geht! Ich erledige ihn. Trefft mich auf der Rückreise — hier, beim selben Wirtshaus."},
          {"D'Artagnan", "Wir reiten."},
          {"SL", "Porthos bleibt. Drei reiten weiter. Cliffhanger für Porthos — sein Duell dauert weiter."}
        ]
      },
      %{
        title: "Drei reiten weiter — Crèvecœur",
        dm:
          "Athos, Aramis, D'Artagnan reiten weiter. Es ist Nacht — schwarz, kalt, der Mond steht hoch. Sie erreichen das nächste Dorf — Crèvecœur — gegen vier Uhr morgens. Sie brauchen wieder Pferdewechsel.",
        core: [
          {"D'Artagnan", "Wir reiten in das Dorf. Sehr ruhig."},
          {"SL", "Wahrnehmungs-Probe."},
          {"Aramis", "Wahrnehmung. Sechzehn."},
          {"SL", "Du siehst — Schatten zwischen den Häusern. Mindestens zwei, vielleicht drei. Hinterhalt."},
          {"Aramis", "Ich warne die Brüder — leise."},
          {"SL", "Bevor ihr reagieren könnt — Schüsse. Eine Musketenkugel trifft Aramis in die Schulter."},
          {"Aramis", "AU. Konstitutionsprobe. Vierzehn — bestanden, ich bleibe bei Bewusstsein. Aber ich bin verwundet."},
          {"SL", "Initiative — Hinterhalt."},
          {"D'Artagnan", "Initiative. Achtzehn."},
          {"Athos", "Initiative. Sechzehn."},
          {"Aramis", "Initiative. Acht — Wunde belastet."},
          {"SL", "Cardinal-Wachen: fünfzehn."},
          {"D'Artagnan", "Ich gehe als erster. Reckless gegen den nächsten Wachpostmen. Trefferversuch mit Vorteil: zweiundzwanzig. Schaden plus Sneak-Attack: vierzehn."}
        ]
      },
      %{
        title: "Aramis fällt aus",
        dm:
          "Der Kampf dauert kurz — drei gegen vier. Athos und D'Artagnan kämpfen mit Verzweiflung. Aramis kann kaum sein Schwert heben.",
        core: [
          {"SL", "Athos schaltet zwei Wachen aus — Smite-Attacken."},
          {"Athos", "Action-Surge — zwei Trefferversuche. Beide Treffer. Vierundzwanzig Schaden zusammen. Beide fallen."},
          {"D'Artagnan", "Letzte Wache — Reckless. Treffer. Schaden zwölf."},
          {"SL", "Letzte Wache fällt. Aber Aramis blutet stark."},
          {"Aramis", "Ich kann nicht reiten. Healing Word reicht für die nächsten Stunden, aber ich kann nicht zu Pferd Tag und Nacht."},
          {"D'Artagnan", "Aramis — Wirtshaus. Du bleibst hier. Wir reiten weiter."},
          {"Aramis", "Ich werde euch erwarten — auf der Rückreise. Hier in Crèvecœur."},
          {"Athos", "Ein Wirt nimmt sich seiner an. D'Artagnan und ich — wir reiten."},
          {"SL", "Aramis im Wirtshaus 'Au Lys d'Argent'. Sein Schultergürtel mit dem Taschentuch von D'Artagnans Zimmer — er hält es fest, als Reliquie an die unbekannte Dame, die er möglicherweise mehr liebt als seinen Priesterruf."}
        ]
      },
      %{
        title: "Zwei reiten weiter — Amiens",
        dm:
          "Athos und D'Artagnan — zwei reiten weiter. Sie erreichen Amiens am späten Nachmittag. Ein größeres Wirtshaus — 'Le Lion d'Or'. Sie brauchen wieder Pferdewechsel und ein paar Stunden Schlaf.",
        core: [
          {"D'Artagnan", "Wir gehen ins Wirtshaus. Athos zahlt — er hat Münzen."},
          {"SL", "Der Wirt — ein dicker Mann mit aufgeklebtem Lächeln — bittet Athos um die Zahlung."},
          {"SL", "Wirt: 'Mein Herr — diese Münzen sind falsch. Schauen Sie — die Prägung ist anders.'"},
          {"Athos", "Insight auf den Wirt. Vierundzwanzig."},
          {"SL", "Athos — du erkennst, der Wirt lügt. Die Münzen sind echt. Das ist eine inszenierte Falle. Cardinal-Geld in seinen Händen, sicher."},
          {"Athos", "Ihr lügt. Die Münzen sind echt. Wer hat euch bezahlt?"},
          {"SL", "Wirt: 'Ihr beleidigt mich, mein Herr! Wachen!'"},
          {"SL", "Zwei städtische Wachen treten ein. Der Wirt zeigt auf Athos."},
          {"D'Artagnan", "Ich kann nicht alle festhalten — Athos, was tust du?"},
          {"Athos", "D'Artagnan — reite weiter. Du allein. Ich halte sie hier auf. Du musst Buckingham erreichen — der Plan steht."},
          {"D'Artagnan", "Athos — ich kann dich nicht zurücklassen — "},
          {"Athos", "Geh! Sofort. Bevor sie das Tor schließen."}
        ]
      },
      %{
        title: "Athos in der Falle",
        dm:
          "D'Artagnan rennt aus der Hintertür. Athos zieht sein Schwert. Initiative — Athos vs zwei Wachen, plus Wirt. Eigentlich gibt's wenig zu würfeln — Athos ist gut, die Wachen mittelmäßig.",
        core: [
          {"Athos", "Wahrscheinlich gewinne ich. Aber ich bin gefangen — kein Pferdewechsel, kein Brot, kein Wein. Inhaftiert."},
          {"SL", "Du gewinnst den Kampf — drei städtische Wachen am Boden. Aber der Wirt hat dich in den Keller gesperrt — mit Schlössern, die du nicht ohne Schlüssel öffnen kannst. Du sitzt im Keller fest."},
          {"Athos", "Wein. Mehr Wein."},
          {"SL", "Im Keller — eigentlich ein Weinkeller — sind dreihundert Flaschen Wein. Athos: 'Ich werde mein Schicksal akzeptieren. Wein für die Wartezeit.'"},
          {"SL", "Du wartest dort — drei Tage. Trinkst Wein. Sehr viel Wein."},
          {"Athos", "Während ich warte, denke ich an Anne de Bueil — die Frau, die ich hängte. War sie wirklich tot? Oder kommt sie zurück?"},
          {"D'Artagnan", "Ich höre das natürlich erst später. Aber ja, Athos — sie kommt zurück."}
        ]
      },
      %{
        title: "D'Artagnan allein — Calais",
        dm:
          "D'Artagnan reitet allein nach Calais. Sein Pferd ist erschöpft. Er nimmt frische Pferde in Boulogne, dann in Calais. Macht eine Konstitutionsprobe.",
        core: [
          {"D'Artagnan", "Konstitution. Mit Vorteil — Inspiration aus der Triple-Duell-Session. Erst zwölf, dann achtzehn. Achtzehn — bestanden."},
          {"SL", "Du erreichst Calais am dritten Reise-Tag. Du brauchst ein Schiff nach England. Die englischen Häfen sind seit Wochen nicht frei für Franzosen — Cardinal Richelieu hat fast einen Krieg arrangiert."},
          {"D'Artagnan", "Ich frage den Hafenmeister."},
          {"SL", "Hafenmeister: 'Junger Herr — ohne Cardinal-Pass kein Schiff. Niemand kommt ohne Cardinal-Pass nach England.'"},
          {"D'Artagnan", "Persuasion. Mit Vorteil — der Saphir-Ring der Königin in meiner Hand."},
          {"D'Artagnan", "Erster Wurf: sechzehn. Zweiter: zweiundzwanzig. Ich nehme zweiundzwanzig."},
          {"SL", "Du zeigst den Saphir-Ring. Der Hafenmeister kennt das Wappen. Er versteht — königliches Geschäft. Aber er weiß nicht, was er tun soll."},
          {"SL", "Hafenmeister: 'Mein Herr — ich kenne einen Mann. Comte de Wardes — er hat heute morgen seinen Cardinal-Pass bekommen. Er ist auf einem Schiff. Wenn ihr den Pass habt — ihr seid drüben.'"},
          {"D'Artagnan", "Comte de Wardes? Wo finde ich ihn?"},
          {"SL", "Hafenmeister: 'Im Wirtshaus 'Goldenes Lilium'. Aber Vorsicht — Wardes ist ein Cardinal-Mann.'"}
        ]
      },
      %{
        title: "D'Artagnan vs. Wardes",
        dm:
          "Im 'Goldenen Lilium' — ein dunkles Wirtshaus, halbleer. Comte de Wardes sitzt mit zwei Begleitern an einem Tisch. Er ist etwa dreißig, gut gekleidet, schmaler Mund. Er trinkt Wein.",
        core: [
          {"D'Artagnan", "Ich gehe direkt auf ihn zu — 'Herr Comte de Wardes — ich brauche euren Cardinal-Pass.'"},
          {"SL", "Wardes lacht. 'Ein junger Geck. Junger Herr — wer seid ihr, dass ihr meinen Pass verlangt?'"},
          {"D'Artagnan", "Ich bin im Auftrag der Königin. Wenn ihr nicht freiwillig — wir duellieren."},
          {"SL", "Wardes: 'Auftrag der KÖNIGIN? Junge — ich diene dem Cardinal. Dein Auftrag ist nichtig.'"},
          {"D'Artagnan", "Initiative."},
          {"SL", "Wardes Initiative: zwanzig. D'Artagnan?"},
          {"D'Artagnan", "Einundzwanzig. Ich gehe zuerst."},
          {"D'Artagnan", "Reckless Attack. Trefferversuch mit Vorteil: dreiundzwanzig. Sneak-Attack — sieben Schaden. Plus regulärer Schaden: dreizehn."},
          {"SL", "Wardes blutet — Wunde an der Brust. Er reagiert."},
          {"SL", "Wardes Trefferversuch: achtzehn — Treffer. Acht Schaden für D'Artagnan."},
          {"D'Artagnan", "Ich nehme. Auf zweiunddreißig HP von vierzig."},
          {"D'Artagnan", "Nächste Runde: Sneak-Attack noch eine. Treffer mit dreiundzwanzig. Vierzehn Schaden."},
          {"SL", "Wardes fällt. Er ist nicht tot — schwer verwundet."}
        ]
      },
      %{
        title: "Mit Wardes' Pass nach England",
        dm:
          "D'Artagnan nimmt den Cardinal-Pass von Wardes. Macht eine Sleight-of-Hand-Probe.",
        core: [
          {"D'Artagnan", "Sleight-of-Hand. Mit Vorteil — eilig. Erster Wurf: vierzehn. Zweiter: einundzwanzig. Ich nehme einundzwanzig."},
          {"SL", "Du nimmst den Pass — und Wardes' Mantel. Der Pass ist mit Wardes' Namen ausgestellt — aber niemand wird vergleichen."},
          {"D'Artagnan", "Ich gehe zum Hafen."},
          {"SL", "Hafenmeister sieht den Pass — Wardes' Name, Cardinal-Siegel. Er nickt. 'Mein Herr — Schiff 'L'Espérance' segelt in zwei Stunden. Ihr habt Platz im Bug.'"},
          {"D'Artagnan", "Ich nehme."},
          {"SL", "Zwei Stunden später — du bist auf hoher See. Ärmelkanal. Wind von Ost. Du wirst seekrank — Konstitutionsprobe."},
          {"D'Artagnan", "Konstitution. Vierzehn — bestanden, knapp. Ich bleibe an Deck."},
          {"SL", "Sieben Stunden Überfahrt. Du erreichst Dover. London ist noch eine Tagesreise."}
        ]
      },
      %{
        title: "Whitehall — Audienz bei Buckingham",
        dm:
          "London. Whitehall-Palast. Der Herzog von Buckingham — George Villiers — ist die rechte Hand des englischen Königs Charles I. Er ist neununddreißig, gut aussehend, raffiniert. Er wird D'Artagnan empfangen — sobald er von der königlichen Saphir-Ring erfährt.",
        core: [
          {"D'Artagnan", "Ich zeige den Saphir-Ring den Wachen. Sie führen mich direkt zu Buckingham."},
          {"SL", "Buckingham im Salon — ein üppiges Zimmer, persische Teppiche, ein Schreibtisch, Gemälde an den Wänden. Er erhebt sich, als du eintritt."},
          {"SL", "Buckingham: 'Bote von ihrer Majestät! Was bringt euch?'"},
          {"D'Artagnan", "Eure Hoheit. Die Königin braucht ihre Anhänger zurück. Cardinal Richelieu plant — '"},
          {"SL", "Buckingham unterbricht: 'Ich weiß, was Richelieu plant. Mein Kammerdiener hat es mir bestätigt. Aber — ich habe ein Problem.'"},
          {"D'Artagnan", "Welches Problem?"},
          {"SL", "Buckingham: 'Vor drei Tagen hat eine Dame mich besucht — Milady de Winter, eine Französin. Sie hat zwei der zwölf Anhänger gestohlen — abgeschnitten, mitten in der Nacht, aus meinem Schmuckkasten. Ich habe es gestern Morgen bemerkt.'"},
          {"D'Artagnan", "ZWEI Anhänger sind WEG?"},
          {"SL", "Buckingham: 'Genau. Aber — ich habe das Geheimnis. Mein Juwelier kann sie reproduzieren. Einige Tage Arbeit, aber er kann es. Bis morgen Abend habe ich zwölf identische Anhänger.'"}
        ]
      },
      %{
        title: "Über Nacht — der Juwelier arbeitet",
        dm:
          "D'Artagnan wartet die Nacht in Whitehall. Er schläft in einem Gästezimmer — luxuriös, aber er ist zu nervös zum Schlafen. Macht eine Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Achtzehn."},
          {"SL", "Du hörst — Schritte im Korridor. Buckingham geht in einem Salon mit jemandem hin und her. Du hörst — Latein? Französisch? Eine ernste Diskussion."},
          {"D'Artagnan", "Wer ist es?"},
          {"SL", "Du lauscht — Buckingham mit einem Juwelier. Sie diskutieren die Diamanten. Der Juwelier sagt: 'Mein Herr — die Diamanten sind aus Indien. Ich brauche fünf identische, perfekte Steine. Ich habe sie. Ich werde bis Sonnenaufgang die Anhänger umnähen.'"},
          {"D'Artagnan", "Ich kann nicht schlafen — ich gehe in den Salon."},
          {"SL", "Buckingham — überrascht — gibt dir ein Wein-Glas. 'D'Artagnan — der Juwelier arbeitet. Wir reisen morgen früh.'"},
          {"D'Artagnan", "Mein Herr — meine Reise hat acht Tage gedauert. Eure Reise kann nicht acht Tage haben."},
          {"SL", "Buckingham: 'Wir brauchen die Anhänger in Paris in drei Tagen. Mein Juwelier ist fertig in zwölf Stunden. Wir reiten direkt — Boot von Dover, Postpferd-Wechsel jede zwanzig Meilen. Ich kann das.'"}
        ]
      },
      %{
        title: "Rückreise mit den Anhängern",
        dm:
          "Sonnenaufgang. Buckingham übergibt D'Artagnan ein kleines Etui — alle zwölf Anhänger, identisch nachgenäht. Sie reisen zusammen nach Dover, dann nimmt ein Schiff D'Artagnan zurück nach Calais. Buckingham reist nicht weiter — er bleibt in England.",
        core: [
          {"SL", "Buckingham: 'D'Artagnan — wenn ihr die Königin seht, sagt ihr — Buckingham liebt sie noch immer. Und er wird sich nie ändern.'"},
          {"D'Artagnan", "Ich werde es ihr sagen."},
          {"SL", "Ein Schiff segelt — der Wind ist günstig. Drei Stunden später bist du in Calais."},
          {"D'Artagnan", "Konstitution für die Rückreise. Vierzehn — bestanden."},
          {"SL", "Du reitest. Den ganzen Tag, die ganze Nacht. Du fällst zweimal vom Pferd vor Erschöpfung. Aber du erreichst Paris — eine Stunde vor dem Ball."},
          {"D'Artagnan", "Eine STUNDE? Knapp."},
          {"SL", "Du eilst zum Louvre. Constance Bonacieux wartet am Diensteingang."},
          {"SL", "Constance: 'D'Artagnan! Bei den Heiligen — ihr habt es geschafft!'"},
          {"D'Artagnan", "Constance — gib das hier der Königin. Sofort."},
          {"SL", "Constance nimmt das Etui. Sie küsst dich — kurz, aber innig. Dann eilt sie davon."}
        ]
      },
      %{
        title: "Der Ball — Königin trägt die Anhänger",
        dm:
          "Im großen Saal des Louvre. Der König Louis XIII auf dem Thron. Königin Anne neben ihm — sie trägt ein silbern-blaues Kleid, das den Hals und die Brust freilässt. Cardinal Richelieu in seinem roten Gewand steht im Hintergrund. Macht eine Wahrnehmungs-Probe für die Atmosphäre.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Sechzehn. Ich versteckt mich in einer Ecke — als Gast getarnt."},
          {"SL", "König Louis: 'Anne, mein Schatz — wo sind deine Anhänger? Du wolltest sie heute Abend tragen.'"},
          {"SL", "Königin Anne — sie sieht zur Tür. Constance erscheint, gibt der Königin ein Wams. Anne nimmt es — geht hinter einen Vorhang. Eine Minute später kommt sie zurück."},
          {"SL", "Königin Anne trägt jetzt — am Hals, in der Brust — die zwölf Diamant-Anhänger."},
          {"SL", "König Louis: 'Ah, hier sind sie. Anne, du siehst wunderschön aus.'"},
          {"SL", "Cardinal Richelieu — sein Gesicht bleibt regungslos. Aber du siehst — kurz — einen Schock. Er wusste, dass zwei Anhänger gestohlen waren. Er hatte sich daran gefreut. Aber jetzt sieht er — alle zwölf. Wie?"},
          {"SL", "Cardinal: 'Eure Hoheit — die Anhänger sind herrlich. Bitte erlauben Sie mir ein Geschenk.' Er reicht der Königin zwei Diamant-Anhänger — die zwei, die Milady gestohlen hatte. 'Ich habe in meinem Schatz zwei Reproduktionen gefunden. Vielleicht möchten Sie sie als Reserve.'"},
          {"SL", "Königin Anne nimmt sie — lächelt — gewinnt das Spiel. Sie zählt jetzt vierzehn Anhänger, aber dem König wird es nicht auffallen."}
        ]
      },
      %{
        title: "Begegnung mit der Königin",
        dm:
          "Nach dem Ball — eine geheime Audienz. D'Artagnan im selben Salon wie vor zwei Wochen.",
        core: [
          {"SL", "Königin Anne: 'D'Artagnan — wie kann ich euch danken?'"},
          {"D'Artagnan", "Ihre Hoheit — ich diene."},
          {"SL", "Königin Anne nimmt einen Ring von ihrer Hand. 'Das ist ein Diamant-Ring. Es ist ein königliches Geschenk. Tragt ihn — er wird euch helfen, wenn ihr je in Not seid.'"},
          {"D'Artagnan", "Ich nehme den Ring — sehr verehrend."},
          {"SL", "Königin Anne: 'Und — sagt euren Freunden meinen Dank. Athos, Porthos, Aramis. Sie haben Opfer gebracht.'"},
          {"D'Artagnan", "Eure Hoheit — wir alle dienen euch."},
          {"SL", "Die Königin verschwindet. D'Artagnan verlässt den Louvre — endlich Schlafen."},
          {"D'Artagnan", "Ich gehe zu Constance — aber sie ist nicht zu Hause. Madame Bonacieux verschwunden."}
        ]
      },
      %{
        title: "Constance ist verschwunden",
        dm:
          "D'Artagnans Zimmer — leer. Konstance ist nicht da. Im unteren Geschoss — die Tür offen, Möbel umgeschmissen. Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Mit Vorteil — Sorge um Constance. Erster Wurf: vierzehn. Zweiter: zwanzig. Ich nehme zwanzig."},
          {"SL", "Du siehst — Spuren von Kampf. Stuhl umgeschmissen. Ein gerissenes Stück Kleidung. Constance hat sich gewehrt."},
          {"SL", "Ein Nachbar — Madame Coquenard — kommt: 'Mein Herr, sie wurde abgeholt. Drei Männer in dunklen Mänteln. Vor zwei Stunden. Sie nahmen sie in eine Kutsche.'"},
          {"D'Artagnan", "Wer? WO?"},
          {"SL", "Coquenard: 'Cardinal-Wachen. Sicher. Die Kutsche hatte das Cardinal-Wappen. Sie fuhren Richtung Süden — vielleicht zum Bastille, vielleicht zu einem Konvent.'"},
          {"D'Artagnan", "Ich muss meine Brüder informieren. Aber zuerst — schlafen. Ich kann nicht mehr."},
          {"SL", "Du schläfst — endlich, nach acht Tagen Reiten. Tief, traumlos."}
        ]
      },
      %{
        title: "Die Brüder kehren zurück",
        dm:
          "Drei Tage später. Porthos kehrt aus Chantilly zurück — sein Duell beendet (er gewann, mit der Hand seines Hauptmann-Gegners), aber er war verwundet und musste sich erholen. Aramis kommt aus Crèvecœur — die Schulter-Wunde heilt langsam. Athos kommt aus Amiens — nach drei Tagen im Weinkeller (er hat eintausend Pistolen Wein-Schaden hinterlassen) und nochmal vier Tage Reisen.",
        core: [
          {"Porthos", "Ich kehre zurück mit einem neuen Pferd und einem Bandage am Bein. Mein Hauptmann-Gegner war stärker, als ich erwartet hatte."},
          {"Aramis", "Ich kehre zurück mit einem dichten Verband um die Schulter. Aber gesund — Cure Wounds und Healing Word haben geholfen."},
          {"Athos", "Ich kehre zurück. Sehr betrunken, vor zwei Tagen. Heute nüchtern. Wein-Konsum dieser Woche: zwei hundert Flaschen."},
          {"D'Artagnan", "Brüder — ihr habt es geschafft. Aber Constance ist verschwunden."},
          {"Athos", "Constance?"},
          {"D'Artagnan", "Cardinal-Wachen haben sie abgeholt. Während wir alle in England waren — ich bin sicher: Constance war im Spiel involviert. Vielleicht hat der Cardinal sie unter Druck setzen wollen — die Königin zu erpressen."},
          {"Aramis", "Wir müssen sie finden."},
          {"Porthos", "Wo sucht man eine entführte Hofdame in Paris?"},
          {"Athos", "Wir suchen nicht in Paris. Wir suchen in der Provinz — Konvent, geheim. Ich kenne ein paar."}
        ]
      },
      %{
        title: "Plan: nach Constance suchen",
        dm:
          "Die vier sitzen wieder am Lagerfeuer in Athos' Quartier. D'Artagnan ist erschöpft aber bestimmt. Athos studiert eine Karte von Frankreich.",
        core: [
          {"Athos", "Drei Möglichkeiten. Konvent von Béthune — Sœurs des Carmélites. Konvent von Saint-Cloud — weit weg. Konvent von Sainte-Geneviève — in Paris, aber unwahrscheinlich, weil Cardinal-Wachen nicht in Paris arbeiten."},
          {"D'Artagnan", "Béthune — am wahrscheinlichsten. Es ist weit, aber sicher gegen Spione."},
          {"Aramis", "Béthune ist ein guter Ort. Stille Karmeliten. Sehr fromm."},
          {"Porthos", "Reisen wir morgen?"},
          {"Athos", "Wir können nicht. Tréville hat uns für La Rochelle eingeplant. Die Belagerung beginnt in einer Woche. Wir gehören zur königlichen Eskorte."},
          {"D'Artagnan", "Constance wartet."},
          {"Aramis", "Wir können sie nach La Rochelle suchen. Erst die Pflicht, dann die Suche."},
          {"D'Artagnan", "Sehr gut. Aber — wenn La Rochelle endet, suchen wir Constance, und Cardinal Richelieu wird mich nicht aufhalten."}
        ]
      },
      %{
        title: "Cliffhanger — La Rochelle ruft",
        dm:
          "Tréville ruft die vier zu sich. Es ist Spätabend. Im Büro — Karten von La Rochelle ausgelegt.",
        core: [
          {"SL", "Tréville: 'Meine Herren — La Rochelle. Die Belagerung beginnt in zehn Tagen. Wir reisen morgen. Eure Aufgabe — Königliche Eskorte. Aber — etwas anderes.'"},
          {"D'Artagnan", "Was anderes, Capitain?"},
          {"SL", "Tréville: 'Cardinal Richelieu hat eine Spionin. Eine Frau. Sie wird euch dort begegnen — sie wird euch versuchen zu manipulieren. Sie heißt Milady de Winter. Hütet euch vor ihr.'"},
          {"Athos", "Milady de Winter? Das ist der Name?"},
          {"SL", "Athos — du blickst weiß. Du erinnerst dich an Anne de Bueil. Die Frau, die du hängtest. Ihre Beschreibung: blond, blau-grau-äugig, Lilien-Brandzeichen auf der linken Schulter."},
          {"Athos", "Capitain — gibt es ein… eine Beschreibung dieser Milady?"},
          {"SL", "Tréville: 'Blond. Blau-grau-äugig. Sehr schön. Etwa fünfundzwanzig. Sie spricht fließend Englisch und Spanisch.'"},
          {"Athos", "Mein Gott."},
          {"D'Artagnan", "Athos — was ist?"},
          {"Athos", "Nichts. Wir reiten morgen. Vier Uhr."},
          {"SL", "Session-Ende. XP — 1200. Inspiration für D'Artagnan — die London-Reise war meisterhaft. Inspiration für Athos — er hat drei Tage Weinkeller-Aufenthalt sehr stilvoll überlebt."},
          {"D'Artagnan", "Ich nehme die Inspiration."},
          {"Athos", "Ich auch. Wenn ich morgen Milady begegne, brauche ich sie."}
        ]
      }
    ]
  end
end

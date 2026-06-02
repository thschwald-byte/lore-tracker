# Session 4 — Lys-Finale
# Quelle: Dumas, Les trois mousquetaires (1844), Kapitel 48-67 (gemeinfrei).
defmodule MusketiereGenerator.S4 do
  def beats do
    [
      %{
        title: "Recap + Planchet kehrt zurück",
        dm:
          "Drei Wochen nach S3. La Rochelle dauert noch an — der Damm fast fertig, aber die Hugenotten halten durch. Im Lager: Planchet, Athos' Diener, kehrt aus London zurück. Er ist erschöpft, aber lebendig. Er trägt eine Nachricht.",
        core: [
          {"SL", "Planchet: 'Mein Herr Athos — Mission erfüllt. Lord de Winter hat Milady festgenommen, sobald sie in Portsmouth ankam. Er hält sie in seinem Landsitz in Sussex.'"},
          {"Athos", "Buckingham?"},
          {"SL", "Planchet: 'Buckingham hat die Warnung erhalten — vor zwölf Tagen. Er hat seine Wachen verdoppelt.'"},
          {"D'Artagnan", "Sehr gut. Aber — Milady wird sich befreien."},
          {"Aramis", "Sie hat Charme. Charme schlägt Wachen."},
          {"Porthos", "Lord de Winter ist klug. Er weiß, wer sie ist."},
          {"Athos", "Lord de Winter ist mein Verbündeter — aber Milady ist gefährlicher als er ahnt."},
          {"SL", "Planchet bringt eine zweite Nachricht — von Bazin. Er ist noch nicht in Béthune angekommen. Reise dauert länger als gedacht."},
          {"D'Artagnan", "Bazin ist zu langsam. Constance ist noch nicht gewarnt."}
        ]
      },
      %{
        title: "In England — Milady gefangen",
        dm:
          "Wir wechseln die Perspektive — der SL erzählt, was in England geschieht. Lord de Winters Landsitz, Sussex. Milady ist in einem Turm-Zimmer eingesperrt — luxuriös aber abgeschlossen. Ein junger Wachmann namens John Felton steht Tag und Nacht vor ihrer Tür.",
        core: [
          {"SL", "Milady — als Gefangene — ist eine andere Frau. Sie betet laut. Sie weint. Sie singt geistliche Lieder."},
          {"SL", "Felton — sechsundzwanzig, sehr fromm, puritanisch, verbissen — er hört."},
          {"SL", "Erste Woche — Milady ignoriert Felton. Zweite Woche — sie spricht mit ihm. Dritte Woche — sie weint vor ihm."},
          {"SL", "Milady: 'Sir Felton — Lord de Winter hält mich, weil ich eine fromme Protestantin bin. Er ist Katholik. Er will mich zwingen, meinen Glauben aufzugeben.'"},
          {"SL", "Felton — Persuasion-Probe vs Miladys Charme: Felton bekommt Wisdom-Save DC 18."},
          {"SL", "Felton würfelt elf. Verfehlt. Er glaubt ihr."},
          {"SL", "Felton: 'Mein Lord ist ein Katholik?'"},
          {"SL", "Milady: 'Ja. Er ist getarnt als Protestant. Aber im Herzen — papistisch. Er hat mich in seine Hände bekommen, weil ich frei sprach gegen den Papst.'"},
          {"SL", "Felton — er ist überzeugt."}
        ]
      },
      %{
        title: "Felton hilft Milady fliehen",
        dm:
          "Sechs Wochen Gefangenschaft. Felton ist vollständig in Milady verliebt — auf eine fromme, fanatische Weise. Er befreit sie eines Nachts.",
        core: [
          {"SL", "Felton: 'Lady — ich helfe euch. Ich werde euch außer Landes bringen.'"},
          {"SL", "Milady: 'Felton — ich bitte um eine letzte Tat. Buckingham — der englische Verräter — er muss sterben. Er hat mein Volk verraten. Wenn ihr ihn tötet, werde ich euch ewig dankbar sein.'"},
          {"SL", "Felton — Wisdom-Save DC 20."},
          {"SL", "Felton würfelt acht. Verfehlt — Milady hat ihn vollständig in der Hand."},
          {"SL", "Felton: 'Ich werde es tun.'"},
          {"SL", "Felton bringt Milady auf ein Schiff nach Calais. Selbst reist er nach Portsmouth — wo Buckingham gerade die Truppen für Frankreich-Hilfe inspiziert."},
          {"D'Artagnan", "Wir wissen das natürlich erst später — durch zeitversetzte Briefe."},
          {"SL", "Genau. Wir wechseln zurück nach Frankreich."}
        ]
      },
      %{
        title: "Buckingham wird ermordet",
        dm:
          "Portsmouth, drei Wochen später. Buckingham bereitet die Flotte vor — siebzig Schiffe sollen nach La Rochelle. Er steht auf dem Pier, schaut über das Meer.",
        core: [
          {"SL", "Felton wartet — als Soldat verkleidet. Er nähert sich Buckingham."},
          {"SL", "Felton: 'Sir — eine Nachricht für euch.'"},
          {"SL", "Buckingham: 'Wartet — ich lese.'"},
          {"SL", "Felton zieht ein langes Messer — und sticht. Trefferversuch — neunzehn. Treffer."},
          {"SL", "Buckingham — Konstitutions-Save DC 18. Acht. Verfehlt. Tödlich verwundet."},
          {"SL", "Buckingham — vor seinen Wachen — fällt zusammen. 'Felton — warum?'"},
          {"SL", "Felton: 'Für Gott. Für Milady de Winter.'"},
          {"SL", "Wachen fassen Felton. Er wehrt sich nicht. Er wird sofort verhaftet."},
          {"SL", "Buckingham stirbt zwei Stunden später. Sein letztes Wort — angeblich ein Name. Anne. Ein letzter Gruß an die Königin Frankreichs."},
          {"D'Artagnan", "Bei den Heiligen. Wir wissen das später — die Nachricht erreicht La Rochelle zwölf Tage später."}
        ]
      },
      %{
        title: "Milady kommt in Béthune an",
        dm:
          "Drei Tage nach Felton-Mord. Milady erreicht Calais, fährt Richtung Béthune. Sie weiß, wo Constance ist — durch Cardinal Richelieus Information. Sie gibt sich als trauernde Witwe aus.",
        core: [
          {"SL", "Konvent in Béthune. Karmeliten-Nonnen. Sehr ruhig. Sehr fromm."},
          {"SL", "Äbtissin Mère Sœur Hélène — etwa fünfzig, weise, vorsichtig."},
          {"SL", "Milady, als 'Madame de Vendôme' getarnt: 'Mutter — ich bitte um Asyl. Mein Mann ist gestorben. Ich brauche Ruhe.'"},
          {"SL", "Äbtissin — Insight-Probe gegen Milady-Persuasion."},
          {"SL", "Äbtissin würfelt sechzehn. Milady würfelt mit Vorteil — einundzwanzig. Milady überzeugt."},
          {"SL", "Äbtissin: 'Madame de Vendôme — ihr seid willkommen. Wir haben eine Schwester, die ihr kennen werdet — auch eine Verbergende. Constance Bonacieux. Sie wird sich freuen, Gesellschaft zu haben.'"},
          {"SL", "Milady: 'Eine Schwester Bonacieux? Was eine Koinzidenz.'"}
        ]
      },
      %{
        title: "Milady trifft Constance",
        dm:
          "Im Konvent — Milady und Constance treffen sich im Garten. Constance kennt Miladys Namen nicht — sie sieht nur eine trauernde Witwe.",
        core: [
          {"SL", "Constance: 'Madame — ihr seid traurig. Habt ihr jemanden verloren?'"},
          {"SL", "Milady: 'Meinen Mann. Vor zwei Wochen. Bei einem Reitunfall.'"},
          {"SL", "Constance: 'Mein Beileid. Ich auch — ich vermisse jemanden. Aber er lebt, hoffentlich.'"},
          {"SL", "Milady — Persuasion-Probe für Charme. Achtzehn."},
          {"SL", "Milady: 'Wen vermisst ihr?'"},
          {"SL", "Constance — Insight-Probe vs Miladys Charme. Constance würfelt zwölf. Verfehlt — sie öffnet sich."},
          {"SL", "Constance: 'Einen jungen Garde-Soldaten. D'Artagnan. Ich war zwei Wochen mit ihm in Paris. Dann musste ich fliehen.'"},
          {"SL", "Milady — innerlich — erkennt: das ist sie. Constance Bonacieux, die für die Königin gearbeitet hat. Cardinal-Richelieu-Auftrag erfüllt."},
          {"SL", "Milady: 'D'Artagnan? Ich kenne den Namen. Sehr… jugendlich.'"},
          {"SL", "Constance: 'Ja. Ich liebe ihn.'"},
          {"SL", "Milady: 'Ah. Trinkt mit mir — auf D'Artagnan. Eine Sherry-Flasche, die ich mitgebracht habe.'"}
        ]
      },
      %{
        title: "La Rochelle fällt — die vier sind frei",
        dm:
          "Zurück in La Rochelle. Eine Woche nach der Buckingham-Nachricht. Die Hugenotten sind ohne Hilfe — Buckingham tot, Flotte nicht gekommen. La Rochelle kapituliert.",
        core: [
          {"SL", "Tréville: 'Meine Herren — La Rochelle hat sich ergeben. Ihr seid frei. Aber Cardinal Richelieu plant — er will euch belohnen oder neue Aufträge geben.'"},
          {"Athos", "Wir reisen sofort. Nach Béthune."},
          {"D'Artagnan", "Tréville — wir bitten um Sondergenehmigung. Wir müssen — privat — etwas erledigen."},
          {"SL", "Tréville: 'Genehmigt. Drei Wochen. Macht euch nicht zu sehr in Cardinal-Augen sichtbar.'"},
          {"Aramis", "Sehr gut."},
          {"SL", "Vier Musketiere brechen sofort auf. Zusätzlich nimmt Athos einen sechsten Reisegenossen mit — den Henker von Lille."},
          {"D'Artagnan", "Wer ist der Henker von Lille?"},
          {"Athos", "Mein Verbündeter. Er hat seine eigene Rechnung mit Milady. Sie hat seinen Bruder — einen Priester — verführt, ihm einen falschen Eid abgenommen, dann hat sie ihn fallen lassen. Der Bruder ist gestorben. Der Henker — Reginald Coquenard — hat geschworen, sie zu strafen."},
          {"Aramis", "Reginald Coquenard. Sehr passend. Henker im Beruf, Henker im Privaten."}
        ]
      },
      %{
        title: "Reise nach Béthune",
        dm:
          "Drei Tage Tag-und-Nacht-Reise. Sechs Reiter — vier Musketiere, Lord de Winter (der aus England rüber kam), Henker von Lille. Sie reiten besessen.",
        core: [
          {"D'Artagnan", "Mein Pferd ist erschöpft. Wir nehmen Pferdewechsel jede zwei Stunden."},
          {"Athos", "Wir reiten weiter. Auch wenn Constance bereits — geschehen ist — wir holen Milady."},
          {"Aramis", "Bazin sollte schon in Béthune sein. Vielleicht hat er die Äbtissin gewarnt."},
          {"SL", "Macht alle Konstitutions-Proben — Tag und Nacht ohne Schlaf."},
          {"D'Artagnan", "Konstitution. Mit Inspiration. Erster Wurf: vierzehn. Zweiter: einundzwanzig. Bestanden."},
          {"Athos", "Konstitution. Achtzehn — bestanden."},
          {"Porthos", "Konstitution. Sechzehn."},
          {"Aramis", "Konstitution. Vierzehn — knapp."},
          {"SL", "Ihr erreicht Béthune am dritten Tag, früh am Nachmittag."}
        ]
      },
      %{
        title: "Konvent in Béthune — zu spät",
        dm:
          "Die vier nähern sich dem Konvent. Hufschlag, Tor offen. Sie reiten direkt in den Innenhof.",
        core: [
          {"D'Artagnan", "Constance! Constance!"},
          {"SL", "Die Äbtissin kommt — sie ist verstört."},
          {"SL", "Äbtissin: 'Meine Herren — bitte — kommt schnell. Schwester Bonacieux — sie ist sehr krank.'"},
          {"D'Artagnan", "Wo ist sie?"},
          {"SL", "Im Krankensaal. Constance liegt — sehr bleich, sehr schwach. Sie zittert. Ihre Augen sind glasig."},
          {"SL", "Constance — kaum mehr in Stimme — sieht D'Artagnan."},
          {"SL", "Constance: 'D'Artagnan — du bist gekommen — '"},
          {"D'Artagnan", "Constance — was ist passiert?"},
          {"SL", "Constance: 'Eine Madame de Vendôme — sie war hier. Sie gab mir einen Sherry. Es war — Gift — '"},
          {"D'Artagnan", "Aramis — schnell — Cure Wounds!"},
          {"Aramis", "Cure Wounds — Stufe drei — Schaden behandelt: dreißig Hitpoints."},
          {"SL", "Constance — atmet noch — aber langsamer. Sie hat zu viel Gift im Körper. Cure Wounds wirkt nur teilweise."}
        ]
      },
      %{
        title: "Constance stirbt",
        dm:
          "Constance liegt — D'Artagnan kniet neben dem Bett. Er hält ihre Hand.",
        core: [
          {"D'Artagnan", "Constance — bleib bei mir."},
          {"SL", "Constance: 'D'Artagnan — ich liebe dich — '"},
          {"D'Artagnan", "Ich liebe dich auch."},
          {"SL", "Constance — ein letzter Atemzug — schließt die Augen. Macht einen Death-Save."},
          {"SL", "Sie würfelt zwei. Erster Fehlschlag. Sie würfelt drei. Zweiter Fehlschlag. Sie würfelt eins — kritisch Fehlgeschlagen. Tot."},
          {"SL", "Constance ist tot."},
          {"D'Artagnan", "ICH NEHME RACHE."},
          {"Athos", "D'Artagnan — wir nehmen Rache. Aber kühl."},
          {"SL", "Die Äbtissin: 'Madame de Vendôme — sie ist vor zwei Stunden weggeritten. Sie sagte: 'Mein Schmerz ist zu groß, ich kann hier nicht bleiben.' Sie hatte ihr Pferd schon bereit.'"},
          {"D'Artagnan", "Wohin?"},
          {"SL", "Äbtissin: 'Sie fuhr in Richtung Süden. Auf der Straße nach Lillers.'"}
        ]
      },
      %{
        title: "Verfolgung — Lillers, dann Armentières",
        dm:
          "Sechs Männer steigen wieder zu Pferde. D'Artagnan, Athos, Porthos, Aramis, Lord de Winter, Henker von Lille. Sie reiten in Richtung Süden — auf Lillers zu.",
        core: [
          {"Athos", "Wir spalten uns. D'Artagnan — du und ich — Hauptstraße nach Süden. Lord de Winter — kleinere Wege links. Porthos — Aramis — Wege rechts. Henker von Lille — du nimmst die direkte Route nach Armentières. Wenn jemand Milady sieht — Pfeife, andere kommen."},
          {"Aramis", "Sehr gut."},
          {"SL", "Sechs reiten in unterschiedliche Richtungen."},
          {"SL", "Drei Stunden später — der Henker von Lille pfeift dreimal kurz. Er hat ein Pferd am Wegesrand gefunden — Damensattel, in Richtung Lys-Fluss."},
          {"D'Artagnan", "Wir folgen den Spuren."},
          {"SL", "Vier Stunden Tracking — Survival-Probe."},
          {"Athos", "Survival. Mit Vorteil — Berry-Erbgut. Erster Wurf: sechzehn. Zweiter: einundzwanzig. Ich nehme einundzwanzig."},
          {"SL", "Du findest sie. Eine kleine Hütte am Lys-Fluss. Rauch aus dem Schornstein. Ihr Pferd ist im Stall."}
        ]
      },
      %{
        title: "Annäherung an die Hütte",
        dm:
          "Die Hütte. Eine alte Bauernkate, halbverfallen, einem Holzfäller gehörig. Stalla daneben. Lys-Fluss zehn Schritte daneben. Mondlicht — die Hütte ist beleuchtet von einer einzigen Kerze.",
        core: [
          {"D'Artagnan", "Wir umstellen die Hütte. Sechs Männer — keine Chance zur Flucht."},
          {"Athos", "Athletik — leise nähern. Erster Wurf: achtzehn. Bestanden."},
          {"SL", "Ihr seid am Hütten-Eingang. Niemand hat euch bemerkt — Milady ist drinnen, im Schein der Kerze."},
          {"D'Artagnan", "Heimlichkeit. Mit Vorteil. Erster Wurf: zweiundzwanzig. Zweiter: vierundzwanzig. Ich nehme vierundzwanzig."},
          {"SL", "Du bist direkt am Fenster. Du siehst Milady drinnen — sie zählt Münzen. Sie hat eine kleine Reisetruhe vor sich. Sie zählt Cardinal-Münzen, leise."},
          {"Athos", "Athos zu allen: 'Auf mein Zeichen — wir betreten. Keine Schüsse. Sie wird gefasst, nicht erschossen.'"}
        ]
      },
      %{
        title: "Festnahme",
        dm:
          "Athos öffnet die Tür mit einem Fußtritt. Milady springt auf — ihr Dolch ist in der Hand.",
        core: [
          {"SL", "Milady: 'Bei den Heiligen — ihr!'"},
          {"Athos", "Anne de Bueil — auch bekannt als Milady de Winter — auch bekannt als Madame de Vendôme — wir sind hier, um euch zu Gericht zu führen."},
          {"SL", "Milady — Initiative."},
          {"SL", "Milady würfelt einundzwanzig. Schnell."},
          {"D'Artagnan", "Initiative. Achtzehn."},
          {"Athos", "Sechzehn."},
          {"Porthos", "Zwölf."},
          {"Aramis", "Vierzehn."},
          {"SL", "Lord de Winter: zwanzig. Henker von Lille: achtzehn."},
          {"SL", "Milady stürmt — sie will durch das Fenster fliehen."},
          {"D'Artagnan", "Ich bin am Fenster. Trefferversuch — Dexterity-Sneak-Attack. Reckless: einundzwanzig. Treffer."},
          {"SL", "Schaden — du willst sie nicht töten, sondern stoppen."},
          {"D'Artagnan", "Stoppen-Aktion — Klinge an den Hals, nicht-tödlich."},
          {"SL", "Milady stoppt — Klinge am Hals. Sie atmet schwer."},
          {"SL", "Athos und der Henker fassen sie. Sie wird gefesselt — an einen Stuhl."}
        ]
      },
      %{
        title: "Das Gerichtsverfahren am Lys",
        dm:
          "Die sechs Männer stehen um Milady. Athos hat einen kleinen Tisch zwischen ihnen — er wird der vorsitzende Richter. Es ist Mitternacht. Mondlicht. Das Lys-Wasser rauscht draußen.",
        core: [
          {"SL", "Athos: 'Anne de Bueil — auch Milady de Winter — auch Madame de Vendôme. Wir haben euch hier, um euch zu Gericht zu stellen. Wir sind sechs. Jeder hat einen Anklagepunkt.'"},
          {"D'Artagnan", "Erste Anklage. Ich, D'Artagnan, klage euch des Mordes an Constance Bonacieux an. Sie wurde mit Gift ermordet, vorgestern in Béthune. Ich war ihr Geliebter. Ich verlange den Tod."},
          {"SL", "Lord de Winter: 'Zweite Anklage. Ich, John Felton's letzte Loyalität — durch euch zerstört. Ihr habt meinen Schwiegersohn zum Mord gestiftet — Buckingham, Herzog von England. Felton wird in zwei Wochen hingerichtet. Ich verlange den Tod.'"},
          {"Athos", "Dritte Anklage. Ich, Comte de la Fère, klage euch der Bigamie und des Verbergens eures wahren Status an. Ihr habt mich geheiratet, ohne mich zu informieren, dass ihr eine wegen Diebstahls Verurteilte seid. Ich verlange den Tod."},
          {"Aramis", "Vierte Anklage. Ich klage euch im Namen der Religion an — ihr habt einen Mann zum Verrat seines Glaubens überredet. Felton war ein guter Christ, ihr habt ihn verdorben."},
          {"Porthos", "Fünfte Anklage. Ihr habt — durch eure Aktionen — sechzigtausend La-Rochelle-Belagerer in unnötige Zeit gezwungen, weil Buckingham bei der Flotte fehlte. Tausende sind gestorben."},
          {"SL", "Henker von Lille: 'Sechste und letzte Anklage. Ich, Reginald Coquenard, Henker von Lille — ihr habt meinen Bruder, Bruder Jean — einen Priester — zum Diebstahl von Kirchengütern verführt, ihn schwängern lassen — sechzehn Jahre alt damals — und ihn dann fallen lassen. Er hat sich erhängt. Ich verlange den Tod als Henker und als Bruder.'"}
        ]
      },
      %{
        title: "Miladys Verteidigung",
        dm:
          "Athos: 'Anne — euer Wort?'",
        core: [
          {"SL", "Milady: 'Meine Herren — ich verteidige mich nicht.'"},
          {"SL", "Sechs Männer warten."},
          {"SL", "Milady: 'Wenn ihr mich tötet, werdet ihr von Gott gerichtet. Ich habe Lieblinge — Cardinal Richelieu wird euch finden.'"},
          {"D'Artagnan", "Eure Schutzbriefe sind nichts. Athos hat sie alle."},
          {"SL", "Athos zieht einen Brief aus seinem Wams. 'Den hier habe ich euch heute Nacht abgenommen, als ich euch fesselte. Carte Blanche. 'Was der Inhaber dieses Briefes getan hat, hat er auf meinen Auftrag und für das Wohl des Königreichs getan. — Cardinal de Richelieu.''"},
          {"SL", "Milady: 'Den Brief — ihr habt ihn?'"},
          {"Athos", "Ja. Den behalte ich."},
          {"D'Artagnan", "Damit ist Milady in keiner Position. Was sagt das Gericht?"},
          {"Athos", "Sechs Stimmen für den Tod. Sechs einstimmig. Die Hinrichtung wird sofort durchgeführt — am Lys."}
        ]
      },
      %{
        title: "Hinrichtung am Lys",
        dm:
          "Sechs Männer führen Milady aus der Hütte. Das Lys-Wasser rauscht. Der Henker von Lille hebt sein Schwert.",
        core: [
          {"SL", "Milady — auf den Knien am Ufer. Sie blickt die sechs Männer an, einen nach dem anderen."},
          {"SL", "Milady: 'D'Artagnan — du wirst es bereuen. Athos — du wirst nie wieder schlafen. Lord de Winter — du wirst keinen Frieden finden. Aramis — dein Gebet wird zu Ohren tauben Engeln. Porthos — du wirst dich nie wieder in deinem Wams freuen. Henker — dein Schwert wird nie sauber sein.'"},
          {"Athos", "Anne — wir handeln aus Pflicht. Nicht aus Hass."},
          {"SL", "Milady senkt den Kopf."},
          {"SL", "Henker von Lille hebt das Schwert — und schlägt zu. Eine schnelle, präzise Bewegung."},
          {"SL", "Miladys Körper fällt — der Kopf rollt ins Lys-Wasser. Stille."},
          {"SL", "Henker: 'Ich bin nicht ein Mörder. Ich bin ein Henker. Es ist mein Beruf, das Recht zu vollstrecken.'"},
          {"SL", "Lord de Winter — bedeckt sein Gesicht."},
          {"D'Artagnan", "Ich sage nichts. Ich denke nur an Constance."},
          {"Athos", "Sie ist tot. Es ist vorbei."}
        ]
      },
      %{
        title: "Rückreise nach Paris",
        dm:
          "Drei Wochen Rückreise. Die vier Musketiere reisen langsam — die Mission ist beendet, das Adrenalin ist weg. Sie reden wenig. Lord de Winter ist nach England zurückgekehrt. Der Henker von Lille — zurück nach Lille.",
        core: [
          {"Athos", "Brüder — ich werde Wein trinken. Sehr viel Wein."},
          {"D'Artagnan", "Athos — Schwüre und Versprechen. Aber zuerst — wir trinken auf Constance."},
          {"Aramis", "Auf Constance."},
          {"Porthos", "Auf Constance."},
          {"Athos", "Auf Constance."},
          {"D'Artagnan", "Es schmerzt — sie war eine Frau, die ich nicht oft sehen konnte. Aber ich liebte sie."},
          {"Athos", "Die Liebe ist immer eine Erinnerung. Ich weiß."},
          {"Aramis", "Sicut dixit dominus — alle Liebe geht durch das Kreuz."},
          {"Porthos", "Ich werde keine Kartoffeln essen, bis wir Paris erreichen."},
          {"D'Artagnan", "Porthos — das ist eine seltsame Trauer."},
          {"Porthos", "Es ist meine Art."}
        ]
      },
      %{
        title: "Cardinal Richelieu lädt D'Artagnan",
        dm:
          "Eine Woche nach Rückkehr in Paris. Ein Bote vom Cardinal — D'Artagnan wird in den Palast Richelieus gerufen. Er geht — vorsichtig, mit Athos' Carte-Blanche-Brief im Wams.",
        core: [
          {"SL", "Cardinal Richelieu — in seinem Studierzimmer. Roter Roben, schmales Gesicht, kleine Augen die alles sehen."},
          {"SL", "Richelieu: 'D'Artagnan. Setzt euch.'"},
          {"D'Artagnan", "Eminenz."},
          {"SL", "Richelieu: 'Mein junger Herr — ihr habt vor zwei Wochen — gemeinsam mit drei Musketieren und zwei anderen — meine engste Mitarbeiterin hingerichtet. Lady de Winter. Eine schreckliche Tat.'"},
          {"D'Artagnan", "Eminenz — ich werde nicht widersprechen."},
          {"SL", "Richelieu: 'Habt ihr keine Verteidigung?'"},
          {"D'Artagnan", "Ich habe — diesen Brief. Den eure Eminenz ausgestellt hat."},
          {"SL", "D'Artagnan zieht den Carte-Blanche-Brief hervor — 'Was der Inhaber dieses Briefes getan hat, hat er auf meinen Auftrag und für das Wohl des Königreichs getan.'"},
          {"SL", "Richelieu — sein Gesicht regt sich nicht. Aber du siehst seine Augen — sie weiten sich."},
          {"SL", "Richelieu: 'Junger Herr — woher habt ihr diesen Brief?'"},
          {"D'Artagnan", "Athos hat ihn — von Milady — am Lys."}
        ]
      },
      %{
        title: "Lieutenant-Patent",
        dm:
          "Cardinal Richelieu — eine seltsame Stille. Dann steht er auf, geht zum Fenster.",
        core: [
          {"SL", "Richelieu: 'D'Artagnan — ihr seid neunzehn?'"},
          {"D'Artagnan", "Zwanzig, Eminenz. Letzte Woche zwanzig geworden."},
          {"SL", "Richelieu: 'Mit zwanzig — bereits Lieutenant der Musketiere?'"},
          {"D'Artagnan", "Eminenz?"},
          {"SL", "Richelieu zieht einen Briefumschlag aus seinem Schreibtisch. 'Hier. Ich habe ihn vorbereitet. Es ist ein Lieutenant-Patent für die Musketier-Kompanie. Wenn ihr es nimmt, dient ihr direkt unter Tréville.'"},
          {"D'Artagnan", "Eminenz — ihr bietet mir ein Patent? Nach allem, was ich getan habe?"},
          {"SL", "Richelieu: 'Nach allem, was ihr getan habt, bin ich beeindruckt. Loyalität, Mut, Schlauheit — selten in einer Person. Ich verzeihe euch das Hinrichten. Es war — politisch — unbequem. Aber jetzt ist es vorbei.'"},
          {"D'Artagnan", "Eminenz — was, wenn ich das Patent ablehne?"},
          {"SL", "Richelieu: 'Dann seid ihr immer noch Garde-Soldat. Aber das Patent — wenn ihr es nehmt — ist es eine königliche Auszeichnung. Tréville wird stolz sein.'"},
          {"D'Artagnan", "Ich nehme das Patent — aber ich erbitte das Recht, es einem meiner Brüder zu geben."},
          {"SL", "Richelieu lächelt — sehr leise. 'Athos hätte es genommen — er ist der älteste. Aber wir wissen beide, Athos wird in den nächsten Monaten in seine Provinz zurückkehren. Porthos wird heiraten — eine reiche Witwe. Aramis wird Priester werden. Sie sind alle bereit, abzudanken. Nehmt ihr das Patent.'"},
          {"D'Artagnan", "Eminenz — ich nehme das Patent. Mit Dankbarkeit."},
          {"SL", "Richelieu: 'Geht. Tréville erwartet euch.'"}
        ]
      },
      %{
        title: "Tréville signiert",
        dm:
          "D'Artagnan im Tréville-Büro. Tréville hat das Patent — Cardinal Richelieu hat es vor zehn Minuten gesandt. Aber das Patent hat keinen Namen — Tréville muss den Namen einsetzen.",
        core: [
          {"SL", "Tréville: 'D'Artagnan — ihr habt euch verdient gemacht. Athos hat mir alles erzählt — die Constance-Sache, die Milady-Sache. Bei den Heiligen — ihr seid eine Legende, mein Junge.'"},
          {"D'Artagnan", "Capitain — ich danke."},
          {"SL", "Tréville: 'Lieutenant-Patent — wessen Name?'"},
          {"D'Artagnan", "Capitain — ich biete es zuerst Athos."},
          {"SL", "Tréville: 'Athos hat es bereits abgelehnt — vor einer Stunde. Er reist morgen in seine Provinz Berry.'"},
          {"D'Artagnan", "Porthos?"},
          {"SL", "Tréville: 'Porthos hat es abgelehnt. Er heiratet in drei Wochen Madame Coquenard — die reiche Witwe seines Wirts in Chantilly. Er wird Kavallerie-Capitain in Picardie.'"},
          {"D'Artagnan", "Aramis?"},
          {"SL", "Tréville: 'Aramis tritt in den Orden der Jesuiten ein. Übermorgen.'"},
          {"D'Artagnan", "Dann — Capitain — ich nehme das Patent."},
          {"SL", "Tréville schreibt: 'D'Artagnan, Lieutenant der königlichen Musketier-Kompanie.' Stempelt. Signiert. Reicht es dir."},
          {"SL", "Tréville: 'Willkommen, Lieutenant.'"}
        ]
      },
      %{
        title: "Letzter Wein mit den Brüdern",
        dm:
          "Eine Woche später. Vier Männer sitzen im 'Pinienzapfen' — das Wirtshaus, wo sie nach dem Triple-Duell zum ersten Mal getrunken haben. Alle vier — vermutlich zum letzten Mal zusammen.",
        core: [
          {"D'Artagnan", "Ich kann es nicht fassen — wir gehen alle in verschiedene Richtungen."},
          {"Athos", "Mein lieber D'Artagnan — wir haben das Beste der Welt erlebt. Drei Duelle, eine Königin, eine Anhänger-Affäre, eine Belagerung, ein Frühstück auf einer Bastion, eine Verschwörung, eine Hinrichtung. Es ist Zeit für Ruhe."},
          {"Porthos", "Madame Coquenard ist eine gute Witwe. Sie hat ein großes Haus in Picardie. Ich werde Capitain einer Kavallerie-Kompanie."},
          {"Aramis", "Der Jesuiten-Orden ist meine Berufung. Ich werde — eines Tages — Bischof. Vielleicht."},
          {"Athos", "Ich kehre nach Berry zurück. Mein Schloss steht leer. Es wartet auf mich. Vielleicht baue ich wieder auf. Vielleicht trinke ich nur Wein."},
          {"D'Artagnan", "Ich bleibe in Paris. Lieutenant der Musketiere. Aber ich werde euch alle besuchen — Porthos in Picardie, Aramis im Orden, Athos in Berry."},
          {"Athos", "D'Artagnan — versprich mir eines. Wenn der König oder die Königin dich braucht — du dienst. Nicht dem Cardinal. Dem König."},
          {"D'Artagnan", "Ich verspreche."},
          {"Porthos", "Auf den König."},
          {"Aramis", "Auf den König."},
          {"Athos", "Auf den König."},
          {"D'Artagnan", "Auf alle vier."},
          {"SL", "Sie trinken — vier alte Freunde — ein letztes Mal zusammen."}
        ]
      },
      %{
        title: "Epilog — Cardinal hört es",
        dm:
          "Eine Woche später. Cardinal Richelieu in seinem Studierzimmer. Vor ihm: Rochefort.",
        core: [
          {"SL", "Richelieu: 'Rochefort — D'Artagnan?'"},
          {"SL", "Rochefort: 'Lieutenant der Musketiere. Sehr loyal zum König und zur Königin. Sehr ehrlich.'"},
          {"SL", "Richelieu: 'Bleibt er gefährlich?'"},
          {"SL", "Rochefort: 'Eminenz — er ist gefährlich. Aber er ist auch nützlich. Wenn Spanien Krieg gegen Frankreich beginnt — und das ist nur eine Frage von wann, nicht ob — werden wir D'Artagnan brauchen.'"},
          {"SL", "Richelieu: 'Lassen wir ihn am Leben. Vorerst.'"},
          {"SL", "Rochefort: 'Und seine Brüder?'"},
          {"SL", "Richelieu: 'Athos, Porthos, Aramis. Ich kenne ihre Schwächen. Ich weiß, wo sie wohnen. Wenn sie nützlich werden — wir wissen, wo sie sind.'"},
          {"SL", "Rochefort: 'Sicut dixit dominus, Eminenz.'"},
          {"SL", "Richelieu — kurz amüsiert: 'Lateinisch. Aramis hat eure Bildung beeinflusst.'"}
        ]
      },
      %{
        title: "Session-Ende — Kampagnen-Ende",
        dm:
          "Letztes Bild. D'Artagnan auf dem Schloss-Hof des Louvre. Königin Anne erscheint. Sie nickt — eine königliche Anerkennung. D'Artagnan verbeugt sich. Tag eins als Lieutenant.",
        core: [
          {"SL", "Königin Anne: 'D'Artagnan — Lieutenant der Musketiere. Mein Herz dankt euch.'"},
          {"D'Artagnan", "Eure Hoheit — ich diene."},
          {"SL", "Königin Anne: 'Und Constance — sie wird nie vergessen werden. Wir haben in Notre-Dame eine Messe für sie. Werdet ihr da sein?'"},
          {"D'Artagnan", "Eure Hoheit — ich werde da sein."},
          {"SL", "Die Königin verschwindet. D'Artagnan steht allein im Hof. Er schaut zur Sonne. Eine neue Phase beginnt."},
          {"SL", "Session-Ende. XP — 1800 pro Charakter — letzte Session, Bonus-XP. Inspiration für alle — die Kampagne ist abgeschlossen."},
          {"D'Artagnan", "Inspiration genommen. Aufgehoben für die nächste Kampagne."},
          {"Athos", "Genommen."},
          {"Porthos", "Genommen. Auf Madame Coquenard."},
          {"Aramis", "Genommen. Sicut dixit dominus."},
          {"SL", "Kampagne 'Die drei Musketiere' beendet. Optional: 'Zwanzig Jahre danach' als Sequel — alle Charaktere zwanzig Jahre älter, Mazarin als neuer Cardinal, Junior-D'Artagnan. Bei Interesse — neue Kampagne, neue Session-Reihe."},
          {"D'Artagnan", "Interesse. Definitiv."},
          {"Athos", "Wir sehen uns."},
          {"Porthos", "Beim Wein."},
          {"Aramis", "In der Kirche."}
        ]
      }
    ]
  end
end

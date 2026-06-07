# Session-1-Beats: „Ein Skandal in Böhmen" — Teil 1 (Auftrag + Feldarbeit bis Trauung).
#
# Buchtreu nach Conan Doyle, „A Scandal in Bohemia" (1891, gemeinfrei). Gespielt
# als CoC/BRP/Gaslight, mythos-frei. SL = „Spielleiter" (spricht Welt + alle NPCs;
# die Figur lebt IM TEXT, z.B. „Der König, hinter der Maske: …"). PCs: „Sherlock
# Holmes", „Dr. Watson".
#
# KONVENTIONEN:
#  * In-Text-Zitate mit typografischen Anführungszeichen „…" bzw. ‚…', NIE mit
#    geraden Quotes — dann braucht der Elixir-String kein Escaping.
#  * Regel-Noise ist DIEGETISCH: eine Probe steht genau dort, wo das Buch eine
#    Handlung hat, die sie auslöst. Der Würfelausgang ist an den Buch-Ausgang
#    gekoppelt (gelingt im Buch → Probe geschafft).
#  * NICHTS wird dazugedichtet; das Volumen kommt aus Doyles tatsächlichem
#    Dialog/Detail, nicht aus Füllmaterial.
#
# Bogen S1: Baker Street (Deduktionen) → der Brief → der maskierte König →
# Enthüllung Wilhelm von Ormstein → das Foto / Irene Adler → Auftrag + Honorar →
# verkleidete Recon an der Briony Lodge → Godfrey Norton → die überraschende
# Trauung → SL-Abbruch („ist spät geworden").

defmodule SkandalGenerator.S1 do
  def beats do
    [
      # ── Rahmen / Wiedersehen ────────────────────────────────────────────
      %{
        dm:
          "Wir steigen ein am Abend des 20. März 1888. Watson, du erzählst das ja im Rückblick — ich gebe dir den Rahmen: Du bist seit einiger Zeit verheiratet, hast deine eigene Praxis, und das häusliche Glück und die Arbeit haben dich von der Baker Street entfremdet. Holmes dagegen meidet die Gesellschaft, lebt in seinen alten Räumen, vergraben in Bücher, abwechselnd von Ehrgeiz getrieben und von der Droge umnachtet. An diesem Abend führt dich dein Heimweg von einem Patienten zufällig die Baker Street entlang. Was geht dir durch den Kopf?",
        core: [
          {"Dr. Watson",
           "Als Erzähler: Ich war an jenem Abend von einem Patienten heimgekehrt, und mein Weg führte mich durch die Baker Street. Als ich an der wohlbekannten Tür vorüberkam, die in meinem Kopf für immer mit meiner Werbung und mit den düsteren Geschehnissen der Studie in Scharlachrot verbunden ist, ergriff mich ein heftiges Verlangen, Holmes wiederzusehen."},
          {"Dr. Watson",
           "Im Spiel: Seine Räume sind hell erleuchtet, und während ich hinaufblicke, sehe ich seine hagere, große Gestalt zweimal als dunkle Silhouette hinter dem Vorhang vorüberziehen. Er schreitet rasch, eifrig, den Kopf auf die Brust gesenkt, die Hände hinter dem Rücken. Mir, der ich jede seiner Stimmungen kenne, sagt das alles: Er ist wieder an der Arbeit. Ich klingle und werde in das Zimmer hinaufgeführt, das einst zum Teil mein eigenes war."},
          {"Sherlock Holmes",
           "Ich empfange dich ohne Überschwang — das tue ich selten —, aber ich bin froh, dich zu sehen. ‚Treten Sie ein, Watson. Setzen Sie sich.'"},
          {"Sherlock Holmes",
           "Ich werfe dir meine Zigarrenkiste zu, deute auf den Spirituskasten und den Gasogen in der Ecke, stelle mich dann vors Feuer und mustere dich auf meine eigentümliche, in sich gekehrte Weise."},
          {"Sherlock Holmes",
           "Die Ehe steht Ihnen gut, Watson. Ich glaube, Sie haben sieben ein halbes Pfund zugenommen, seit ich Sie zuletzt sah."},
          {"Dr. Watson", "Sieben, möchte ich meinen."},
          {"Sherlock Holmes",
           "Wahrhaftig, ich hätte ein wenig mehr gedacht. Nur ein ganz klein wenig mehr, Watson. Und wieder in der Praxis, wie ich sehe. Sie sagten mir nicht, dass Sie vorhätten, sich wieder ins Geschirr zu legen."},
          {"Dr. Watson", "Aber woher wissen Sie das alles?"},
          {"Sherlock Holmes",
           "Ich sehe es, ich schließe es. Wie weiß ich, dass Sie sich neulich gehörig durchnässt haben und dass Sie ein höchst ungeschicktes und unachtsames Dienstmädchen haben?"}
        ]
      },
      %{
        dm:
          "Beobachtung ist Holmes' Paradedisziplin. Holmes, gib mir eine Entdecken-Probe.",
        core: [
          {"Sherlock Holmes",
           "Entdecken — ich würfle 17, mein Wert ist 75. Glänzend geschafft."},
          {"Dr. Watson",
           "Mein lieber Holmes, das geht zu weit. Vor ein paar Jahrhunderten hätte man Sie verbrannt. Es stimmt, dass ich am Donnerstag einen Spaziergang über Land gemacht habe und gründlich durchnässt heimkam; aber ich habe die Kleider gewechselt — ich kann mir nicht denken, wie Sie es herleiten. Und was Mary Jane angeht — sie ist unverbesserlich, meine Frau hat ihr bereits gekündigt; doch auch da sehe ich nicht, wie Sie darauf kommen."},
          {"Sherlock Holmes",
           "Es ist die Einfachheit selbst. Mein Auge sagt mir, dass an der Innenseite Ihres linken Schuhs, gerade dort, wo das Feuer ihn bescheint, das Leder von sechs nahezu parallelen Schnitten zerkratzt ist. Offensichtlich hat jemand sehr achtlos rings um den Rand der Sohle geschabt, um angetrockneten Schmutz zu entfernen. Daraus folgere ich zweierlei: dass Sie bei scheußlichem Wetter draußen waren, und dass Sie ein besonders bösartiges, stiefelschlitzendes Exemplar der Londoner Dienstmädchenschaft besitzen."},
          {"Sherlock Holmes",
           "Was Ihre Praxis betrifft — wenn ein Herr in mein Zimmer tritt und nach Jodoform riecht, mit einem schwarzen Höllenstein-Fleck am rechten Zeigefinger und einer Ausbuchtung an der rechten Seite seines Zylinders, die anzeigt, wo er sein Stethoskop verborgen hat, dann müsste ich stumpfsinnig sein, ihn nicht für ein tätiges Mitglied der Ärzteschaft zu erklären."},
          {"Dr. Watson",
           "Wenn Sie es erklären, kommt es mir stets so lächerlich einfach vor, dass ich es selbst leicht könnte — und doch bin ich bei jedem neuen Beispiel verblüfft, bis Sie mir Ihren Gedankengang aufschlüsseln."},
          {"Sherlock Holmes",
           "Ganz recht. Sie sehen, aber Sie beobachten nicht. Der Unterschied ist klar. Zum Beispiel haben Sie die Stufen oft gesehen, die vom Flur in dieses Zimmer heraufführen."},
          {"Dr. Watson", "Häufig."},
          {"Sherlock Holmes", "Wie oft?"},
          {"Dr. Watson", "Nun, einige hundert Mal."},
          {"Sherlock Holmes", "Und wie viele sind es?"},
          {"Dr. Watson", "Wie viele? Das weiß ich nicht."},
          {"Sherlock Holmes",
           "Eben! Sie haben nicht beobachtet, und doch gesehen. Genau das meine ich. Nun, ich weiß, dass es siebzehn Stufen sind, denn ich habe sowohl gesehen als auch beobachtet. — Übrigens, da Sie sich für diese kleinen Probleme interessieren und so gütig waren, den einen oder anderen meiner unbedeutenden Fälle aufzuzeichnen, dürfte Sie dies hier interessieren."}
        ]
      },
      # ── Der Brief ───────────────────────────────────────────────────────
      %{
        dm: "",
        core: [
          {"Sherlock Holmes",
           "Ich werfe dir einen Bogen dicken, rosafarbenen Briefpapiers zu, der offen auf dem Tisch lag. ‚Es kam mit der letzten Post. Lesen Sie es laut.'"},
          {"Dr. Watson",
           "Ich lese vor: ‚Es wird Sie heute Abend, um drei Viertel acht, ein Herr aufsuchen, der Sie in einer Angelegenheit von höchster Wichtigkeit zu konsultieren wünscht. Ihre jüngsten Dienste für eines der königlichen Häuser Europas haben gezeigt, dass man Ihnen Dinge anvertrauen darf, deren Bedeutung kaum zu überschätzen ist. Diesen Bericht über Sie haben wir von allen Seiten erhalten. Seien Sie zu jener Stunde in Ihren Räumen, und deuten Sie es nicht als Beleidigung, wenn Ihr Besucher eine Maske trägt.'"},
          {"Dr. Watson", "Das ist in der Tat ein Geheimnis. Was, denken Sie, hat es zu bedeuten?"},
          {"Sherlock Holmes",
           "Noch habe ich keine Daten. Es ist ein kapitaler Fehler, zu theoretisieren, ehe man Daten hat. Unmerklich beginnt man, Fakten zu verdrehen, damit sie zu Theorien passen, statt Theorien, damit sie zu den Fakten passen. Doch der Brief selbst — was leiten Sie aus ihm ab?"},
          {"Dr. Watson",
           "Ich untersuche ihn als Praktiker. Der Mann, der ihn schrieb, ist vermutlich wohlhabend. Solches Papier kostet nicht unter einer halben Krone das Päckchen. Es ist eigentümlich kräftig und steif."},
          {"Sherlock Holmes",
           "Eigentümlich — das ist das richtige Wort. Es ist überhaupt kein englisches Papier. Halten Sie es gegen das Licht."},
          {"SL", "Halt den Bogen gegen die Lampe — gib mir eine Entdecken-Probe."},
          {"Dr. Watson",
           "Entdecken — 38 gegen meinen Wert von 55. Geschafft. Ich halte ihn ans Licht und sehe ein Wasserzeichen, in das Papier eingewebt: ein großes ‚E' mit einem kleinen ‚g', dann ein ‚P', und ein großes ‚G' mit einem kleinen ‚t'."},
          {"Sherlock Holmes", "Was machen Sie daraus?"},
          {"Dr. Watson", "Den Namen des Herstellers, ohne Zweifel; oder vielmehr sein Monogramm."},
          {"Sherlock Holmes",
           "Mitnichten. Das ‚G' mit dem kleinen ‚t' steht für ‚Gesellschaft' — die deutsche Entsprechung unseres ‚Co.'. ‚P' steht natürlich für ‚Papier'. Nun zum ‚Eg'. Werfen wir einen Blick in unser Ortslexikon."},
          {"Sherlock Holmes", "Ich nehme den schweren braunen Ortslexikon-Band vom Regal und reiche ihn dir."},
          {"SL", "Watson, deine Domäne — gib mir eine Probe auf Bibliotheksnutzung."},
          {"Dr. Watson",
           "Bibliotheksnutzung — 22 auf 60. Sitzt. Ich blättere zum Kontinent: ‚Eglow … Eglonitz … hier — Egria. Deutschsprachiges Land, in Böhmen, unweit von Karlsbad. Bemerkenswert als Sterbeort Wallensteins und durch seine zahlreichen Glashütten und Papiermühlen.' Aha — was halten Sie davon?"},
          {"Sherlock Holmes",
           "Das Papier wurde in Böhmen hergestellt. Und der Mann, der den Satz formte, ist ein Deutscher. Beachten Sie den eigentümlichen Bau: ‚Diesen Bericht über Sie haben wir von allen Seiten erhalten.' Ein Franzose oder Russe hätte das nicht so geschrieben. Der Deutsche ist es, der so rücksichtslos mit seinen Verben verfährt. Es bleibt also nur zu klären, was dieser Böhme will, der auf böhmischem Papier schreibt und es vorzieht, eine Maske zu tragen — und, wenn ich mich nicht irre, kommt er soeben, um all unsere Zweifel zu lösen."}
        ]
      },
      # ── Die Kutsche / der maskierte Besucher ───────────────────────────
      %{
        dm:
          "Während Holmes spricht, hört ihr das scharfe Geräusch von Pferdehufen und Rädern, die am Bordstein schaben, gefolgt von einem heftigen Zug an der Klingel. Holmes pfeift. — ‚Ein Zweispänner, nach dem Klang. Ja. Ein hübsches kleines Brougham und ein schönes Paar Pferde. Hundertfünfzig Guineen das Stück. An diesem Fall ist Geld, Watson, wenn nichts anderes.’ Schwere, langsame Schritte auf der Treppe und im Gang halten vor der Tür inne. Dann lautes, gebieterisches Klopfen.",
        core: [
          {"Dr. Watson", "Soll ich gehen?"},
          {"Sherlock Holmes",
           "Keineswegs, Doktor. Bleiben Sie, wo Sie sind. Ich bin verloren ohne meinen Boswell. Und dies verspricht interessant zu werden. Es wäre jammerschade, es zu versäumen. — Herein!"},
          {"SL",
           "Herein tritt ein Mann, der kaum unter sechs Fuß sechs messen kann, mit der Brust und den Gliedern eines Herkules. Seine Kleidung ist von einer Pracht, die in England als geschmacklos gälte: schwere Astrachan-Streifen quer über Ärmel und Brust des zweireihigen Rocks, ein tiefblauer, am Hals von einer Brosche aus einem einzigen flammenden Beryll gehaltener Umhang, scharlachrot gefüttert. Stiefel bis zur halben Wade hinauf, oben mit reichem braunem Pelz besetzt, vollenden den Eindruck barbarischer Üppigkeit. In der Hand hält er einen breitkrempigen Hut; über dem oberen Teil des Gesichts trägt er, bis hinab über die Wangenknochen, eine schwarze Maske, die er offenbar erst eben angelegt hat."},
          {"SL",
           "Der Maskierte, mit dickem deutschem Akzent: ‚Sie haben meine Notiz erhalten? Ich teilte Ihnen mit, dass ich kommen würde.' Er blickt von einem zum anderen, als wisse er nicht, an wen er sich zu wenden hat."},
          {"Sherlock Holmes",
           "Bitte, nehmen Sie Platz. Dies ist mein Freund und Kollege, Dr. Watson, der gelegentlich die Güte hat, mir bei meinen Fällen beizustehen. Wen habe ich die Ehre anzureden?"},
          {"SL",
           "‚Sie dürfen mich Graf von Kramm nennen, einen böhmischen Edelmann. Ich darf wohl annehmen, dass dieser Herr, Ihr Freund, ein Mann von Ehre und Verschwiegenheit ist, dem ich eine Angelegenheit von höchster Tragweite anvertrauen darf? Wenn nicht, zöge ich es weit vor, mit Ihnen allein zu sprechen.'"},
          {"Dr. Watson", "Ich erhebe mich, um zu gehen."},
          {"Sherlock Holmes", "Ich ergreife dich am Handgelenk und drücke dich zurück in den Sessel. — Bleib."},
          {"Sherlock Holmes", "Beide, oder keiner. Sie dürfen vor diesem Herrn alles sagen, was Sie mir sagen können."},
          {"SL",
           "Der Graf zuckt die breiten Schultern. ‚Dann muss ich Sie beide zunächst zu absolutem Stillschweigen für zwei Jahre verpflichten; nach Ablauf dieser Frist wird die Sache ohne Belang sein. Gegenwärtig ist es nicht zu viel gesagt, dass sie von solchem Gewicht ist, dass sie den Lauf der europäischen Geschichte beeinflussen könnte.'"},
          {"Sherlock Holmes", "Ich verspreche es."},
          {"Dr. Watson", "Und ich."},
          {"SL",
           "‚Verzeihen Sie diese Maske', fährt der seltsame Besucher fort. ‚Die erlauchte Person, in deren Auftrag ich handle, wünscht, dass ihr Beauftragter Ihnen unbekannt bleibe, und ich gestehe sogleich, dass der Titel, den ich eben nannte, nicht ganz der meine ist.'"},
          {"Sherlock Holmes", "Das war mir bewusst."}
        ]
      },
      # ── Enthüllung: der König ──────────────────────────────────────────
      %{
        dm:
          "Ein gespannter Moment — der Maskierte wartet auf eine Antwort. Spielt das groß aus.",
        core: [
          {"SL", "Holmes, gib mir eine Psychologie-Probe auf den Maskierten."},
          {"Sherlock Holmes", "Psychologie — 24, mein Wert ist 70. Mühelos."},
          {"Sherlock Holmes",
           "Die Umstände sind von großer Heikelkeit, und alle Vorsichtsmaßregeln müssen getroffen werden, um etwas zu ersticken, das zu einem ungeheuren Skandal anwachsen und eines der regierenden Häuser Europas ernstlich kompromittieren könnte. Offen gesagt: Die Sache betrifft das große Haus Ormstein, die erblichen Könige von Böhmen."},
          {"SL",
           "Der Besucher fährt vom Stuhl auf und schreitet in unbändiger Erregung im Zimmer auf und ab. Dann reißt er sich mit einer Gebärde der Verzweiflung die Maske vom Gesicht und schleudert sie zu Boden. ‚Sie haben recht', ruft er, ‚ich BIN der König. Warum sollte ich versuchen, es zu verhehlen?'"},
          {"Sherlock Holmes",
           "Warum, in der Tat? Eure Majestät hatten noch kein Wort gesprochen, da war mir bereits bewusst, dass ich Wilhelm Gottsreich Sigismond von Ormstein vor mir hatte, Großherzog von Cassel-Felstein und erblicher König von Böhmen."},
          {"SL",
           "Der König, nun ohne Maske — ein offenes, hochmütiges Gesicht, eine kühne, gerade Nase, große dunkle Augen — setzt sich wieder: ‚Aber Sie können verstehen, dass ich nicht gewohnt bin, derlei Dinge persönlich zu erledigen. Doch die Sache war so heikel, dass ich sie keinem Beauftragten anvertrauen konnte, ohne mich in seine Gewalt zu begeben. Ich bin inkognito aus Prag gekommen, eigens, um Sie zu Rate zu ziehen.'"},
          {"Sherlock Holmes", "So ziehen Sie mich zu Rate."}
        ]
      },
      # ── Das Problem: Irene Adler + das Foto ─────────────────────────────
      %{
        dm:
          "Der König fährt sich mit der Hand über die hohe, weiße Stirn und beginnt. Ich spiele ihn — das ist der Kern des Auftrags.",
        core: [
          {"SL",
           "Der König: ‚Die Sache liegt kurz so. Vor etwa fünf Jahren, während eines längeren Aufenthalts in Warschau, machte ich die Bekanntschaft der wohlbekannten Abenteurerin Irene Adler. Der Name ist Ihnen zweifellos vertraut.'"},
          {"Sherlock Holmes",
           "Schlagen Sie sie bitte in meinem Register nach, Doktor. — Ich führe seit Jahren ein System, in dem ich Tatsachen über Menschen und Dinge ablege, sodass es schwerfällt, einen Gegenstand oder eine Person zu nennen, über die ich nicht sogleich Auskunft geben könnte."},
          {"Dr. Watson",
           "Ich finde die Karte zwischen der eines hebräischen Rabbiners und der eines Stabsoffiziers, der eine Abhandlung über die Tiefseefische geschrieben hat. Ich lese: ‚Irene Adler. Geboren in New Jersey im Jahre 1858. Kontra-Altistin — hm! La Scala — hm! Primadonna der Kaiserlichen Oper zu Warschau — ja! Zog sich von der Opernbühne zurück — ha! Lebt in London — ganz recht!'"},
          {"SL", "Der König nickt: ‚Eben die.'"},
          {"Sherlock Holmes",
           "Eure Majestät ließen sich also mit dieser jungen Person ein, schrieben ihr einige kompromittierende Briefe und möchten diese Briefe nun zurückhaben."},
          {"SL", "‚Ganz recht. Aber wie —'"},
          {"Sherlock Holmes", "Gab es eine heimliche Heirat?"},
          {"SL", "‚Keine.'"},
          {"Sherlock Holmes", "Keine Urkunden, keine Zeugnisse?"},
          {"SL", "‚Keine.'"},
          {"Sherlock Holmes",
           "Dann kann ich Eurer Majestät nicht folgen. Wenn diese junge Person die Briefe zur Erpressung oder zu anderem Zweck vorzeigte — wie wollte sie ihre Echtheit beweisen?"},
          {"SL", "‚Da ist die Handschrift.'"},
          {"Sherlock Holmes", "Pah, pah! Gefälscht."},
          {"SL", "‚Mein eigenes Briefpapier.'"},
          {"Sherlock Holmes", "Gestohlen."},
          {"SL", "‚Mein eigenes Siegel.'"},
          {"Sherlock Holmes", "Nachgemacht."},
          {"SL", "‚Meine Fotografie.'"},
          {"Sherlock Holmes", "Gekauft."},
          {"SL", "‚Wir waren beide darauf.'"},
          {"Sherlock Holmes", "Du meine Güte! Das ist sehr schlimm. Eure Majestät haben in der Tat eine Unklugheit begangen."},
          {"SL", "‚Ich war von Sinnen — verrückt.'"},
          {"Sherlock Holmes", "Sie haben sich ernstlich kompromittiert."},
          {"SL", "‚Ich war damals nur Kronprinz. Ich war jung. Ich bin heute erst dreißig.'"},
          {"Sherlock Holmes", "Sie muss wiederbeschafft werden."},
          {"SL", "‚Wir haben es versucht und sind gescheitert.'"},
          {"Sherlock Holmes", "Eure Majestät müssen zahlen. Sie muss gekauft werden."},
          {"SL", "‚Sie will nicht verkaufen.'"},
          {"Sherlock Holmes", "Gestohlen, dann."},
          {"SL",
           "‚Fünf Versuche wurden unternommen. Zweimal ließ ich durch von mir bezahlte Einbrecher ihr Haus durchsuchen. Einmal entwendeten wir ihr Gepäck auf einer Reise. Zweimal wurde sie überfallen. Es war kein Ergebnis zu erzielen.'"},
          {"Sherlock Holmes", "Keine Spur davon?"},
          {"SL", "‚Nicht die geringste.'"},
          {"Dr. Watson", "Ich werfe als Praktiker eine Frage ein: Warum sollte sie das Bild überhaupt verwenden wollen?"},
          {"SL",
           "Der König wendet sich an dich: ‚Sie droht, es zu senden. Und das wird sie tun. Ich weiß, dass sie es tun wird. Sie hat eine eiserne Natur. Sie hat das Gesicht der schönsten Frau und den Sinn des entschlossensten Mannes. Eher als dass ich sie einen anderen Mann heiraten ließe, gäbe es keine Länge, zu der sie nicht ginge — keine.'"},
          {"SL",
           "Der König weiter: ‚Ich bin im Begriff, mich zu vermählen — mit Clotilde Lothman von Sachsen-Meiningen, der zweiten Tochter des Königs von Skandinavien. Sie kennen vielleicht die strengen Grundsätze ihrer Familie. Sie selbst ist der Inbegriff der Zartheit. Ein Schatten des Zweifels an meiner Aufführung würde alles beenden. Irene Adler hat geschworen, das Bild zu senden — am Tage meiner öffentlichen Verlobung. Das wird der erste Montag nächster Woche sein.'"},
          {"Sherlock Holmes",
           "Oh, dann bleiben uns noch drei Tage. Das trifft sich gut, denn ich habe ein oder zwei Dinge von Belang zu erledigen. Eure Majestät werden vorerst in London bleiben?"},
          {"SL", "‚Gewiss. Sie finden mich im Langham, unter dem Namen Graf von Kramm.'"}
        ]
      },
      # ── Honorar + Adresse ──────────────────────────────────────────────
      %{
        dm:
          "Bevor der König geht, das Geschäftliche — das gehört bewusst dazu (Auftrag UND Honorar sollen im Resümee stehen).",
        core: [
          {"Sherlock Holmes", "Und das Honorar?"},
          {"SL", "‚Sie haben freie Hand.'"},
          {"Sherlock Holmes", "Vollkommen?"},
          {"SL",
           "‚Ich sage Ihnen, ich gäbe eine der Provinzen meines Königreichs für jene Fotografie.' Der König greift unter seinen Umhang und legt einen schweren Beutel aus Gemsleder auf den Tisch. ‚Dreihundert Pfund in Gold und siebenhundert in Banknoten', sagt er."},
          {"Sherlock Holmes", "Ich kritzle eine Quittung auf ein Blatt meines Notizbuchs und reiche sie ihm hinüber."},
          {"Sherlock Holmes", "Und die Adresse der Dame?"},
          {"SL", "‚Briony Lodge, Serpentine Avenue, St. John's Wood.'"},
          {"Dr. Watson", "Ich notiere mit: Briony Lodge, Serpentine Avenue, St. John's Wood. Habe ich."},
          {"Sherlock Holmes", "Eine letzte Frage: War die Fotografie im Kabinettformat?"},
          {"SL", "‚Das war sie.'"},
          {"Sherlock Holmes",
           "Dann gute Nacht, Eure Majestät, und ich vertraue darauf, dass wir bald gute Nachrichten für Sie haben werden. — Und gute Nacht, Watson. Wenn Sie morgen Nachmittag um drei Uhr vorbeischauen, würde ich gern mit Ihnen über diese kleine Angelegenheit plaudern."}
        ]
      },
      # ── Recon: Holmes verkleidet ───────────────────────────────────────
      %{
        dm:
          "Schnitt — der nächste Nachmittag, kurz vor drei, Baker Street. Holmes ist noch aus; Watson wartet am Feuer. Gegen vier öffnet sich die Tür.",
        core: [
          {"Dr. Watson",
           "Herein torkelt ein angetrunken wirkender Stallknecht — ungekämmt, mit Backenbart, entzündeten Augen, schäbiger Kleidung. Ich muss ihn dreimal ansehen, ehe ich sicher bin, wer das ist."},
          {"SL", "Watson, gib mir eine Psychologie-Probe — durchschaust du den Mann?"},
          {"Dr. Watson",
           "Psychologie — 44 auf 60. Geschafft, aber erst auf den zweiten Blick. Großer Gott, Holmes — Sie hatten mich völlig getäuscht!"},
          {"Sherlock Holmes",
           "Ich nicke dir nur zu, verschwinde ins Schlafzimmer und komme im Tweed wieder heraus, sauber und gepflegt wie eh und je. Verkleiden hatte ich am Vormittag gewürfelt — 22 auf 75. ‚Ich verließ das Haus heute Morgen um acht Uhr in der Gestalt eines arbeitslosen Stallknechts. Es herrscht eine wunderbare Anteilnahme und Freimaurerei unter den Pferdeleuten. Sei einer von ihnen, und du wirst alles erfahren, was es zu wissen gibt.'"},
          {"Sherlock Holmes",
           "Ich fand die Briony Lodge bald. Ein Schmuckkästchen von Villa, vorn bis dicht an die Straße gebaut, mit einem Garten hinten, zwei Stockwerke, ein Chubb-Schloss an der Tür. Großes Vorderzimmer rechts, gut möbliert, mit langen Fenstern fast bis zum Boden und diesen lächerlichen englischen Fensterriegeln, die ein Kind öffnen könnte. Ich schlenderte die Straße hinab und fand, wie ich erwartet hatte, einen Stallhof in einer Gasse, die an einer Mauer des Gartens entlangläuft. Ich half den Knechten beim Striegeln der Pferde und erhielt dafür zwei Pence, ein Glas Halb-und-halb, zwei Pfeifenfüllungen Tabak und so viele Auskünfte über Fräulein Adler, wie ich mir nur wünschen konnte — von einem halben Dutzend Leute der Nachbarschaft obendrein, an denen mir nicht das Geringste lag."}
        ]
      },
      %{
        dm:
          "Holmes berichtet, was er über Irene Adler erfahren hat — verbürgtes Wissen aus dem Buch, gehört ins Resümee.",
        core: [
          {"Sherlock Holmes",
           "Sie hat allen Männern der Gegend den Kopf verdreht. Sie ist das niedlichste Geschöpf unter einem Hut auf diesem Planeten — so heißt es einstimmig in den Serpentine Mews. Sie lebt still, singt bei Konzerten, fährt täglich um fünf aus und kehrt Punkt sieben zum Abendessen heim. Sonst geht sie selten aus, außer wenn sie singt."},
          {"Sherlock Holmes",
           "Sie hat nur einen einzigen männlichen Besucher — aber den reichlich. Er ist dunkel, gutaussehend, schneidig, kommt nie seltener als einmal, oft zweimal am Tag. Ein gewisser Mr. Godfrey Norton, vom Inner Temple. Sehen Sie die Vorzüge eines Kutschers als Vertrauten? Sie hatten ihn ein Dutzend Mal von den Serpentine Mews heimgefahren und wussten alles über ihn."},
          {"Dr. Watson", "Und wer ist dieser Norton — was ist er ihr?"},
          {"Sherlock Holmes",
           "Eben das ist die Frage. Ist er ihr Anwalt? Ihr Freund? Ihr Liebhaber? Wenn er ihr Anwalt ist, hat sie ihm vermutlich die Fotografie zur Verwahrung übergeben. Wenn er ihr Liebhaber ist, ist das weit weniger wahrscheinlich. Von der Antwort hängt ab, ob ich meine Arbeit in der Briony Lodge fortsetze oder meine Aufmerksamkeit den Kanzleien des Herrn im Temple zuwende. — Und gerade während ich darüber nachdachte, überschlugen sich die Dinge."}
        ]
      },
      # ── Die überraschende Trauung ──────────────────────────────────────
      %{
        dm:
          "Holmes erzählt weiter aus seinem Bericht; ihr erlebt es mit ihm. Eine Droschke rast vor die Briony Lodge.",
        core: [
          {"Sherlock Holmes",
           "Eine Droschke fuhr vor, und ein Herr sprang heraus. Ein bemerkenswert gutaussehender Mann, dunkel, mit Adlernase, schnurrbärtig — offenbar der Mann, von dem ich gehört hatte. Er schien in größter Eile, rief dem Kutscher zu, er solle warten, und stürmte an dem Mädchen vorbei, das die Tür geöffnet hatte, mit der Miene eines Mannes, der völlig zu Hause ist."},
          {"Sherlock Holmes",
           "Er blieb etwa eine halbe Stunde, und ich erhaschte durch die Fenster des Salons Schemen von ihm, wie er auf und ab schritt, erregt redete und mit den Armen fuchtelte. Von ihr sah ich nichts. Dann trat er wieder heraus, noch aufgeregter als zuvor. Beim Besteigen der Droschke zog er eine goldene Uhr aus der Tasche und blickte angelegentlich darauf."},
          {"SL",
           "Ich spiele Norton, im Hinausstürzen zum Kutscher: ‚Fahren Sie wie der Teufel! Erst zu Gross & Hankey in der Regent Street, dann zur St.-Monika-Kirche in der Edgware Road. Eine halbe Guinee, wenn Sie es in zwanzig Minuten schaffen!'"},
          {"Sherlock Holmes",
           "Fort waren sie, und ich überlegte gerade, ob ich nicht folgen sollte, da kam ein zierliches Landauer-Coupé die Gasse herauf, der Kutscher mit halb zugeknöpftem Mantel, die Krawatte unter dem Ohr, das ganze Riemenzeug aus den Schnallen hängend. Es hatte kaum gehalten, da schoss sie aus der Haustür und hinein. Ich sah sie nur einen Augenblick — doch sie war eine reizende Frau, mit einem Gesicht, für das ein Mann sterben könnte."},
          {"SL", "Ich spiele Irene, im Hineileilen: ‚Die St.-Monika-Kirche, John, und einen halben Sovereign, wenn Sie es in zwanzig Minuten schaffen!'"}
        ]
      },
      %{
        dm:
          "An der Kirche braucht es Schnelligkeit und Glück. Holmes, gib mir eine Glücks-Probe.",
        core: [
          {"Sherlock Holmes",
           "Das war zu schön, um es zu versäumen, Watson. Ich überlegte gerade, ob ich laufen oder mich hinten an das Landauer hängen sollte, da kam eine Droschke die Straße herauf. Der Kutscher sah zweimal auf eine so schäbige Gestalt, doch ich sprang hinein, ehe er Einwände erheben konnte. — Glück: ich würfle 29, mein Glück steht auf 75. Geschafft."},
          {"Sherlock Holmes",
           "‚Die St.-Monika-Kirche', sagte ich, ‚und einen halben Sovereign, wenn Sie in zwanzig Minuten dort sind.' Es war zwölf Uhr fünfunddreißig, und natürlich war völlig klar, was im Gange war. Mein Kutscher fuhr schnell. Ich glaube nicht, dass ich je schneller gefahren bin, doch die anderen waren vor mir da. Das Coupé und das Landauer standen mit dampfenden Pferden vor der Tür, als ich ankam. Ich zahlte und eilte in die Kirche."},
          {"Sherlock Holmes",
           "Es war keine Seele darin außer den beiden, denen ich gefolgt war, und einem Geistlichen im Chorrock, der ihnen offenbar Vorhaltungen machte. Alle drei standen vor dem Altar zusammengedrängt. Ich schlenderte das Seitenschiff hinauf wie ein Müßiggänger, der zufällig in eine Kirche geraten ist. Da plötzlich, zu meiner Überraschung, fuhren die drei am Altar herum und mir zu, und Godfrey Norton kam, so schnell er konnte, auf mich zugerannt."},
          {"SL", "Norton, atemlos: ‚Gott sei Dank! Sie genügen. Kommen Sie! Kommen Sie!'"},
          {"Sherlock Holmes", "Was denn?"},
          {"SL",
           "Norton zerrt dich zum Altar: ‚Kommen Sie, Mann, kommen Sie — nur drei Minuten, sonst ist es nicht gesetzmäßig!' Ihr begreift: die Trauung sollte um Punkt zwölf vollzogen sein, die Lizenz läuft sonst ab, und sie brauchten unbedingt einen Trauzeugen. Der erste Beste, der zur Tür hereinkam, war ein verlotterter Stallknecht."}
        ]
      },
      %{
        dm:
          "Der zentrale Plot-Punkt von Teil 1: Holmes wird, ausgerechnet, Trauzeuge — Irene Adler heiratet Godfrey Norton.",
        core: [
          {"Sherlock Holmes",
           "Ich wurde halb zum Altar gezerrt, und ehe ich wusste, wie mir geschah, murmelte ich Antworten, die mir ins Ohr geflüstert wurden, bürgte für Dinge, von denen ich nichts wusste, und half ganz allgemein, Irene Adler, ledige Jungfer, sicher und fest mit Godfrey Norton, Junggeselle, zu verbinden. Es war in einem Augenblick getan, und da stand der Herr dankend zu meiner einen Seite, die Dame zur anderen, während der Geistliche mir gegenüber strahlte. Es war die widersinnigste Lage, in der ich mich je befand; der Gedanke daran brachte mich eben zum Lachen."},
          {"Sherlock Holmes",
           "Es scheint, dass in ihrer Lizenz ein Formfehler steckte, dass der Geistliche sich rundheraus weigerte, sie ohne irgendeinen Zeugen zu trauen, und dass mein glückliches Erscheinen den Bräutigam der Not enthob, in die Gassen hinauszustürzen, um einen Brautführer zu suchen. Die Braut gab mir einen Sovereign, und ich gedenke, ihn an meiner Uhrkette zu tragen, zur Erinnerung an diesen Anlass."},
          {"Dr. Watson", "Das ist eine höchst unerwartete Wendung. Und was nun? Ändert die Heirat Ihre Pläne?"},
          {"Sherlock Holmes",
           "Sie bedroht sie sehr. Doch auf den Kirchenstufen verabredeten die beiden sich, getrennte Wege zu gehen — er zurück in den Temple, sie um sieben zum Abendessen heim. Es bleibt mir also noch der Abend. Wir müssen handeln, ehe sich Neues ergibt."}
        ]
      },
      # ── SL-Abbruch (Session-Ende) ──────────────────────────────────────
      %{
        dm:
          "Holmes will gerade seinen Plan für den Abend entwickeln — und hier breche ich als SL ab. Spielt das aus, wie es bei uns am Tisch eben läuft.",
        core: [
          {"SL",
           "Ach, schaut mal auf die Uhr — das ist ja schon weit nach elf. Lasst uns hier einen Schnitt machen; den Plan für den Coup nehmen wir uns nächste Woche frisch vor, dann hat Watson auch von Anfang an seine Aufgabe dabei."},
          {"Dr. Watson", "Einverstanden. Ich bin ohnehin reif fürs Bett."},
          {"Sherlock Holmes",
           "Gut. Behaltet im Kopf, wo wir stehen: Das Foto liegt in der Briony Lodge, Irene ist seit heute Mittag mit Godfrey Norton verheiratet, und morgen — beziehungsweise nächstes Mal — locken wir das Bild ans Licht. Bis dahin, Watson."},
          {"SL", "Dann machen wir für heute Schluss. Nächste Woche, gleiche Zeit — und ich fasse zu Beginn kurz zusammen, wo wir stehen."}
        ]
      }
    ]
  end
end

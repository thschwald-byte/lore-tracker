# Session-2-Beats: „Ein Skandal in Böhmen" — Teil 2 (der Coup + die Umkehrung).
#
# Buchtreu nach Conan Doyle (Konventionen siehe s1_beats.exs: typografische
# Anführungszeichen statt gerader Quotes; Proben DIEGETISCH an den
# Handlungspunkten; nichts dazugedichtet). Beginnt mit „Was letztes Mal geschah".
#
# Bogen S2: Recap → der Feueralarm-Plan → Watsons Rolle (Rauchrakete) → die
# Ausführung an der Briony Lodge → Irene verrät das Versteck → „Gute Nacht,
# Mister Sherlock Holmes" (die Umkehrung) → nächster Morgen mit dem König →
# Flucht, Brief, Foto → Holmes' Honorar: „die Frau".

defmodule SkandalGenerator.S2 do
  def beats do
    [
      # ── Recap ───────────────────────────────────────────────────────────
      %{
        dm:
          "Bevor wir einsteigen, kurz: Was letztes Mal geschah. Der König von Böhmen, Wilhelm von Ormstein, hat Holmes beauftragt, eine kompromittierende Fotografie zurückzubeschaffen — sie zeigt ihn und die Opernsängerin Irene Adler gemeinsam; Irene droht, das Bild am Tag seiner Verlobung an die Familie seiner Braut, der Prinzessin Clotilde, zu senden. Holmes hat verkleidet an der Briony Lodge recherchiert und ist dabei zufällig Trauzeuge geworden, als Irene Adler den Anwalt Godfrey Norton heiratete. Das Foto liegt weiterhin im Haus. Heute holen wir es. Watson, du bist von Anfang an dabei.",
        core: [
          {"Dr. Watson",
           "Ich bin am Abend wieder in der Baker Street. Holmes empfängt mich in bester Laune. Sie sagten, Sie bräuchten meine Hilfe heute Abend — wozu?"},
          {"Sherlock Holmes",
           "Ich bin froh, dass Sie gekommen sind. Es kann nichts schaden, dass Sie an meiner Seite sind. — Es ist nichts Ungesetzliches dabei, doch ich brauche einen Zeugen, dem ich vertraue. Watson, wollen Sie mir helfen?"},
          {"Dr. Watson", "Von ganzem Herzen."},
          {"Sherlock Holmes",
           "Es macht Ihnen nichts aus, das Gesetz zu brechen?"},
          {"Dr. Watson", "Nicht im Geringsten."},
          {"Sherlock Holmes",
           "Noch eine Verhaftung zu riskieren?"},
          {"Dr. Watson", "Nicht in guter Sache."},
          {"Sherlock Holmes", "Oh, die Sache ist vortrefflich!"},
          {"Dr. Watson", "Dann bin ich Ihr Mann."},
          {"Sherlock Holmes", "Ich war sicher, dass ich mich auf Sie verlassen kann."}
        ]
      },
      # ── Der Plan ──────────────────────────────────────────────────────
      %{
        dm:
          "Holmes legt den Plan dar — das Herzstück. Ich lass ihn ausreden; Watson, du wirst gleich gebraucht.",
        core: [
          {"Sherlock Holmes",
           "Als sie heiratete, vereinfachte das die Sache. Die Fotografie wird nun für sie zur zweischneidigen Waffe. Sie scheut es ebenso, dass Mr. Godfrey Norton sie zu Gesicht bekommt, wie unser Klient es scheut, dass sie seiner Prinzessin in die Hände fällt. Die Frage ist allein: Wo werden wir die Fotografie finden?"},
          {"Dr. Watson", "Wo, in der Tat?"},
          {"Sherlock Holmes",
           "Es ist höchst unwahrscheinlich, dass sie sie bei sich trägt. Sie ist im Kabinettformat — zu groß, um sie bequem im Kleid einer Frau zu verbergen. Sie weiß, dass der König imstande ist, sie überfallen und durchsuchen zu lassen. Zwei Versuche dieser Art sind bereits unternommen worden. Wir dürfen also annehmen, dass sie sie nicht mit sich führt."},
          {"Dr. Watson", "Wo also dann?"},
          {"Sherlock Holmes",
           "Ihr Bankier oder ihr Anwalt. Doch ich neige zu keiner der beiden Annahmen. Frauen sind von Natur verschwiegen und besorgen ihre Geheimnisse gern selbst. Warum sollte sie es einem anderen aushändigen? Ihrer eigenen Obhut durfte sie trauen; aber wie sich der mittelbare oder politische Einfluss auf einen Geschäftsmann auswirken könnte, ließ sich nicht absehen. Überdies bedenken Sie: Sie war entschlossen, es binnen weniger Tage zu verwenden. Es muss daher dort sein, wo sie es greifbar hat. Es muss in ihrem eigenen Hause sein."},
          {"Dr. Watson", "Aber zweimal wurde dort eingebrochen."},
          {"Sherlock Holmes",
           "Pah! Sie verstanden nicht, wie man sucht."},
          {"Dr. Watson", "Aber wie wollen Sie suchen?"},
          {"Sherlock Holmes",
           "Ich werde nicht suchen. Ich werde sie es mir zeigen lassen. — Wenn eine Frau glaubt, ihr Haus stünde in Flammen, treibt sie der Instinkt sogleich zu dem, was ihr das Teuerste ist. Es ist ein vollkommen unwiderstehlicher Antrieb, und ich habe mehr als einmal Nutzen daraus gezogen. Eine verheiratete Frau ergreift ihr Kind, eine ledige ihren Schmuckkasten. Nun, mir ist klar, dass es in unserem Hause kein teureres Gut gibt als das, was wir suchen. Mrs. Norton wird hineilen, um es zu sichern. Der Feueralarm wird vortrefflich nachgeahmt werden. Und Sie werden, wenn ich meine Hand hebe, das hier ins Zimmer werfen und gleichzeitig ‚Feuer!' rufen. Verstehen Sie mich?"}
        ]
      },
      %{
        dm:
          "Holmes weist Watson die Rolle zu — das ist der mechanische Kern des Coups, gehört wörtlich erfasst. Er zieht eine lange, zigarrenförmige Rolle aus der Tasche.",
        core: [
          {"SL",
           "Holmes hält dir den Gegenstand hin: ‚Es ist eine gewöhnliche Klempner-Rauchrakete, an beiden Enden mit einer Zündkapsel versehen, sodass sie sich selbst entzündet. Ihre Aufgabe beschränkt sich darauf. Wenn Sie Ihren Feuerruf erheben, wird er von einer ganzen Anzahl Menschen aufgenommen werden. Sie können dann an das Ende der Straße gehen, und ich werde in zehn Minuten zu Ihnen stoßen.'"},
          {"Dr. Watson",
           "Ich fasse zusammen, damit nichts schiefgeht: Ich verhalte mich neutral, harre am offenen Fenster, behalte Sie im Auge, und auf Ihr Handzeichen werfe ich dies hier hinein, rufe Feuer und ziehe mich dann an die Straßenecke zurück."},
          {"Sherlock Holmes", "Ganz genau."},
          {"Dr. Watson", "Dann dürfen Sie sich vollkommen auf mich verlassen."},
          {"Sherlock Holmes",
           "Das ist vortrefflich. Es ist wohl bald Zeit, dass ich mich für die neue Rolle vorbereite, die ich zu spielen habe."},
          {"SL",
           "Holmes verschwindet im Schlafzimmer und kehrt nach wenigen Minuten als freundlicher, einfältiger Nonkonformisten-Geistlicher zurück — breiter schwarzer Hut, weite Hose, weißes Halstuch, ein mitfühlendes Lächeln und ein Gesamtausdruck neugierig-wohlwollender Anteilnahme. SL-seitig hat Holmes seine Verkleiden-Probe erneut bestanden (im Buch makellos)."},
          {"Sherlock Holmes",
           "Verkleiden — 22, mein Wert ist 75. Sitzt. Es ist nicht bloß der Anzug, Watson, der sich ändert. Der Ausdruck, die Haltung, die Seele selbst wandeln sich mit der Rolle, die man annimmt."}
        ]
      },
      %{
        dm:
          "Es ist ein Viertel nach sechs, als ihr die Baker Street verlasst, und zehn vor sieben erreicht ihr die Serpentine Avenue. Es dämmert; die Lampen werden angezündet, während ihr vor der Briony Lodge auf und ab geht und auf die Heimkehrende wartet. Die Straße ist belebter, als man es für eine so stille Gegend erwartete.",
        core: [
          {"Sherlock Holmes",
           "Sehen Sie, die Heirat vereinfacht alles. Die Fotografie ist nun beiden eine Last. Doch beachten Sie die Gesellschaft hier: eine Schar schäbiger Männer, die an der Ecke rauchen und lachen, ein Scherenschleifer mit seinem Rad, zwei Gardisten, die mit einem Kindermädchen scherzen, und mehrere gutgekleidete junge Männer, die mit Zigarren im Mund umherschlendern."},
          {"Dr. Watson",
           "Eine Probe — Entdecken — ob mir an der Menge etwas auffällt? 71 auf 55. Daneben. Mir scheint die Ansammlung nicht besonders verdächtig."},
          {"Sherlock Holmes",
           "Sie ahnen nicht, dass diese müßigen Gestalten mein eigenes Werk sind, jede mit ihrem Stichwort versehen. Doch das tut nichts zur Sache — solange ich diese Fotografie nicht in Händen habe. — Da, hören Sie. Räder."},
          {"SL",
           "Und Punkt sieben rollt das kleine Landauer-Coupé die Serpentine Avenue herauf. Es biegt um die Ecke und hält vor der Tür der Briony Lodge."}
        ]
      },
      # ── Ausführung ──────────────────────────────────────────────────────
      %{
        dm:
          "In dem Moment, in dem der Wagen hält, bricht der inszenierte Tumult los — Holmes hat die Müßiggänger im Voraus angeworben. Ich erzähle, ihr greift ein, wo es passt.",
        core: [
          {"Sherlock Holmes",
           "Als die Dame ausstieg, stürzte einer der zerlumpten Kerle herbei, um gegen ein Trinkgeld den Schlag zu öffnen, wurde aber von einem anderen weggestoßen, der in gleicher Absicht herbeigeeilt war. Ein wüster Streit brach aus, die beiden Gardisten ergriffen für den einen Partei, der Scherenschleifer ebenso hitzig für den anderen. Im Nu war die Dame von einem ringenden Knäuel erhitzter Männer umringt, die wild mit Fäusten und Stöcken aufeinander einschlugen."},
          {"Sherlock Holmes",
           "Ich stürzte in das Gedränge, um die Dame zu schützen. Doch gerade als ich sie erreichte, stieß ich einen Schrei aus und fiel zu Boden, das Gesicht von Blut überströmt. SL-seitig: eine kleine Schauspielerei meinerseits — ein Tropfen Farbe und ein Sturz im rechten Moment."},
          {"SL", "Holmes, mach mir dafür eine Probe — sagen wir Verkleiden für die vorgetäuschte Verletzung. Im Buch wirkt sie vollkommen."},
          {"Sherlock Holmes", "Verkleiden — 31, Wert 75. Überzeugend. Bei meinem Sturz stoben die Gardisten in die eine Richtung davon, die Strolche in die andere."},
          {"SL",
           "Ich spiele Irene, erschrocken über den am Boden liegenden Geistlichen: ‚Ist der arme Herr schwer verletzt?' Stimmen aus der Menge: ‚Er ist tot!' — ‚Nein, nein, er lebt noch!' — ‚Aber er wird es nicht bis ins Krankenhaus schaffen.'"},
          {"SL",
           "Irene, mit Entschluss: ‚Er ist ein tapferer Mann. Sie hätten der Dame Tasche und Uhr genommen, wäre er nicht gewesen. Tragt ihn herein. Bringt ihn in den Salon. Hier — legt ihn aufs Sofa.' Und so wirst du, scheinbar besinnungslos, in die Briony Lodge getragen und im Vorderzimmer aufs Sofa gebettet."}
        ]
      },
      %{
        dm:
          "Watson, dein großer Moment naht — du bist am offenen Fenster. Behalt Holmes' Hand im Blick.",
        core: [
          {"Sherlock Holmes",
           "Man bettete mich aufs Sofa beim Fenster. Ich tat, als ränge ich nach Luft; das Dienstmädchen öffnete das Fenster, wie ich gehofft hatte. Im selben Augenblick hob ich die Hand."},
          {"Dr. Watson",
           "Das ist mein Stichwort. SL, ich werfe die Rauchrakete präzise durchs offene Fenster — eine kleine Wurf-Probe? Geschicklichkeit — 40 auf 60. Geschafft. Und ich rufe aus voller Kehle: ‚Feuer! Feuer!'"},
          {"SL",
           "Kaum ist das Wort heraus, fällt die ganze Menge der Zuschauer, vornehm und schäbig durcheinander, in den Ruf ein: ‚Feuer!' Dicke Rauchschwaden quellen durch den Raum und aus dem offenen Fenster. Ich sehe hastende Gestalten, und einen Augenblick später Irenes Stimme von drinnen, die alle beschwichtigt, es sei falscher Alarm."},
          {"Dr. Watson",
           "Ich gleite, wie verabredet, aus dem Gewühl und ziehe mich an die Straßenecke zurück. Nach zehn Minuten stößt Holmes zu mir, und wir eilen aus der Gegend fort."}
        ]
      },
      %{
        dm:
          "Der Kern-Erfolg des Coups — Holmes hat im Tumult genau beobachtet, wohin Irene griff. Holmes, eine Entdecken-Probe vom Sofa aus; im Buch sieht er es klar.",
        core: [
          {"Sherlock Holmes",
           "Entdecken — 19, Wert 75. Glasklar gesehen. Beim Ruf ‚Feuer!' tat sie genau, was ich vorhergesehen hatte. Eine Frau, jäh erschreckt, eilt zu dem, was ihr das Teuerste ist. Mrs. Norton stürzte unfehlbar zu ihrem Schatz."},
          {"Sherlock Holmes",
           "Die Fotografie liegt in einer Aussparung hinter einer verschiebbaren Holzplatte, gleich über dem rechten Klingelzug. Sie war dort in einem Augenblick, und ich erhaschte sogar einen Blick darauf, wie sie sie halb hervorzog. Als ich aber rief, es sei falscher Alarm, legte sie sie zurück, warf einen Blick auf die Rakete, eilte aus dem Zimmer, und ich sah sie nicht wieder. Ich erhob mich, entschuldigte mich und entkam aus dem Hause."},
          {"Dr. Watson", "Das ist meisterhaft. Sie wissen nun, wo es liegt. Holen wir es gleich?"},
          {"Sherlock Holmes",
           "Ich zögerte, ob ich mich der Fotografie sogleich bemächtigen sollte. Doch der Kutscher war hereingekommen, und da er mich scharf beobachtete, schien es sicherer zu warten. Allzu große Hast verdirbt alles. Morgen früh holen wir es — und zwar mit dem König und Ihnen zusammen. Wir werden in den Salon geführt, um auf die Dame zu warten, doch wahrscheinlich wird sie, wenn sie kommt, weder uns noch die Fotografie vorfinden. Es wird Seiner Majestät eine Genugtuung sein, sie mit eigener Hand zurückzuerlangen."}
        ]
      },
      # ── Die Umkehrung ──────────────────────────────────────────────────
      %{
        dm:
          "Auf dem Heimweg zur Baker Street, kurz vor der Tür — eine Kleinigkeit, die sich erst später als die entscheidende erweist. Ein schlanker Jüngling in einem langen Ulster geht eilig vorbei.",
        core: [
          {"SL",
           "Ich spiele den vorbeihastenden Burschen im Ulster, der im Vorübergehen halb über die Schulter sagt: ‚Gute Nacht, Mister Sherlock Holmes.' Und schon ist er die Straße hinunter im Gewühl verschwunden."},
          {"Sherlock Holmes",
           "Ich habe diese Stimme schon einmal gehört. Nur — hol's der Henker, ich wüsste gern, wer das war."},
          {"SL", "Holmes, eine Probe — Erinnern oder Horchen, ob du die Stimme zuordnest. Im Buch gelingt es dir nicht."},
          {"Sherlock Holmes",
           "Erinnern — ich würfle 88, mein Wert ist 65. Daneben. Nein, es will mir nicht einfallen. Ein junger Mann, schlank, in einem Ulster, der es eilig hatte. Kommen Sie, Watson, es ist spät, und ich brauche Schlaf. Morgen um acht sind wir mit Seiner Majestät zur Stelle."}
        ]
      },
      # ── Nächster Morgen: die Flucht ─────────────────────────────────────
      %{
        dm:
          "Am nächsten Morgen, Punkt acht. Der König trifft in der Baker Street ein, voller Ungeduld, und gemeinsam fahrt ihr zur Briony Lodge. Ich spiele den König und gleich die alte Haushälterin.",
        core: [
          {"SL",
           "Der König, kaum eingetreten, ergreift Holmes bei beiden Schultern: ‚Sie haben es wirklich? Sie haben die Fotografie?'"},
          {"Sherlock Holmes", "Noch nicht."},
          {"SL", "‚Aber Sie haben Hoffnung?'"},
          {"Sherlock Holmes", "Ich habe Hoffnung."},
          {"SL", "‚Dann kommen Sie. Ich kann es kaum erwarten, weiterzukommen.'"},
          {"Sherlock Holmes", "Wir brauchen eine Droschke."},
          {"SL", "‚Nein, mein Brougham wartet draußen.'"},
          {"SL",
           "Ihr fahrt vor. Die Tür der Briony Lodge öffnet sich, noch ehe ihr klingelt — eine ältliche Frau steht auf der Schwelle und mustert euch mit sardonischem Blick, während ihr aus dem Brougham steigt. Ich spiele sie: ‚Mr. Sherlock Holmes, nicht wahr?'"},
          {"Sherlock Holmes", "Ich bin Mr. Holmes."},
          {"SL",
           "Die Haushälterin: ‚In der Tat! Meine Herrin sagte mir, dass Sie wahrscheinlich vorsprechen würden. Sie reiste heute Morgen mit ihrem Gatten ab, mit dem Zug fünf Uhr fünfzehn von Charing Cross, auf den Kontinent.'"},
          {"Sherlock Holmes", "Was?!"},
          {"SL", "Holmes, du taumelst zurück, weiß vor Verdruss und Überraschung."},
          {"Sherlock Holmes",
           "Sie meinen, sie hat England verlassen?"},
          {"SL", "Die Haushälterin: ‚Für immer.'"}
        ]
      },
      %{
        dm:
          "Holmes stürmt in den Salon, an die Klingelschnur, schiebt die Holzplatte beiseite — und findet nicht, was er erwartet. Die große Umkehrung.",
        core: [
          {"Sherlock Holmes",
           "Ich eile durch den Salon zur verschiebbaren Platte über dem rechten Klingelzug und reiße sie auf — ist sie fort?"},
          {"SL",
           "In der Aussparung liegt eine Fotografie — aber nicht die gefürchtete. Es ist ein Bild Irene Adlers allein, im Abendkleid. Und daneben ein Brief, adressiert: ‚An Sherlock Holmes, Esq. Wird abgeholt.'"},
          {"Sherlock Holmes",
           "Holmes reißt ihn auf. Ich lese ihn euch laut vor — er ist auf Mitternacht datiert: ‚Mein lieber Mr. Sherlock Holmes — Sie haben es wirklich sehr gut gemacht. Sie täuschten mich vollkommen. Bis nach dem Feuerlärm hegte ich nicht den geringsten Argwohn. Doch dann, als ich merkte, wie ich mich verraten hatte, begann ich nachzudenken.'"}
        ]
      },
      %{
        dm:
          "Ich spiele Irenes Brief als ihre Stimme weiter — der Schlüssel zur Umkehrung: SIE hat IHN durchschaut. Buchtreu, gehört vollständig ins Resümee.",
        core: [
          {"SL",
           "Irenes Brief, in ihrer Stimme: ‚Man hatte mich schon vor Monaten vor Ihnen gewarnt. Man sagte mir, falls der König einen Beauftragten anstelle, dann gewiss Sie. Und Ihre Adresse hatte man mir gegeben. Und doch brachten Sie mich, bei alldem, dazu, Ihnen zu enthüllen, was Sie wissen wollten. Selbst nachdem ich Argwohn schöpfte, fiel es mir schwer, an einem so lieben, gütigen alten Geistlichen Böses zu denken.'"},
          {"SL",
           "‚Aber, Sie wissen, ich bin selbst für die Bühne ausgebildet. Männerkleidung ist mir nichts Neues. Oft nutze ich die Freiheit, die sie gewährt. Ich schickte John, den Kutscher, Sie zu beobachten, lief nach oben, schlüpfte in meine Spazierkleidung, wie ich sie nenne, und kam herab, gerade als Sie gingen.'"},
          {"SL",
           "‚Nun, ich folgte Ihnen bis an Ihre Tür und vergewisserte mich, dass ich tatsächlich ein Objekt des Interesses für den berühmten Mr. Sherlock Holmes war. Dann wünschte ich Ihnen, recht unbesonnen, eine gute Nacht und ging zum Temple, meinen Mann aufzusuchen.'"},
          {"Sherlock Holmes",
           "Der Bursche im Ulster — das war sie. Beim Himmel, Watson, was für eine Frau! Hörten Sie, wie sie mir gute Nacht wünschte, und ich erkannte sie nicht?"},
          {"SL",
           "Der Brief schließt: ‚Wir beide hielten Flucht für das beste Mittel, einem so gewaltigen Gegner zu entkommen; so werden Sie das Nest leer finden, wenn Sie morgen vorsprechen. Was die Fotografie betrifft, so mag Ihr Klient ruhen. Ich liebe und werde geliebt von einem besseren Mann, als er es ist. Der König mag tun, was er will, ohne Hindernis durch eine, der er bitter unrecht getan hat. Ich behalte die Fotografie nur zu meinem eigenen Schutz und als Waffe, die mich gegen jeden Schritt sichert, den er künftig unternehmen könnte. Ich hinterlasse eine Fotografie, die er vielleicht gern besäße. Und ich verbleibe, lieber Mr. Sherlock Holmes, sehr ergebenst die Ihre, Irene Norton, geborene Adler.'"}
        ]
      },
      # ── Auflösung + das Honorar ─────────────────────────────────────────
      %{
        dm:
          "Reaktion des Königs — und Holmes' berühmtes Honorar. Spielt es aus.",
        core: [
          {"SL",
           "Der König, fassungslos: ‚Was für eine Frau — oh, was für eine Frau! Sagte ich Ihnen nicht, wie rasch und entschlossen sie ist? Wäre sie nicht eine bewundernswerte Königin gewesen? Ist es nicht ein Jammer, dass sie nicht auf meiner Ebene stand?'"},
          {"Sherlock Holmes",
           "Nach allem, was ich von der Dame gesehen habe, scheint sie in der Tat auf einer ganz anderen Ebene zu stehen als Eure Majestät. Es tut mir leid, dass ich die Angelegenheit Eurer Majestät nicht zu einem glücklicheren Abschluss bringen konnte."},
          {"SL",
           "Der König: ‚Im Gegenteil, mein lieber Herr! Ein glücklicherer Abschluss ist nicht denkbar. Ich weiß, dass ihr Wort unverbrüchlich ist. Die Fotografie ist nun so sicher, als läge sie im Feuer.'"},
          {"Sherlock Holmes", "Es freut mich, Eure Majestät das sagen zu hören."},
          {"SL",
           "Der König: ‚Ich stehe unermesslich in Ihrer Schuld. Bitte, sagen Sie mir, womit ich Sie belohnen kann. Dieser Ring —' Er streift einen Smaragd-Schlangenring von der Hand und hält ihn auf der Handfläche dar."},
          {"Sherlock Holmes", "Eure Majestät besitzen etwas, das ich noch höher schätze."},
          {"SL", "‚Sie brauchen es nur zu nennen.'"},
          {"Sherlock Holmes", "Diese Fotografie!"},
          {"SL", "Der König starrt ihn verblüfft an: ‚Irenes Fotografie? Gewiss, wenn Sie es wünschen.'"},
          {"Sherlock Holmes",
           "Ich danke Eurer Majestät. Dann ist in dieser Sache nichts weiter zu tun. Ich habe die Ehre, Ihnen einen sehr guten Morgen zu wünschen. — Ich verbeuge mich, übersehe die Hand, die er mir hinstreckt, und nehme die Fotografie an mich."}
        ]
      },
      %{
        dm:
          "Der Schluss-Beat: Watsons Erzähler-Nachwort und die berühmte Pointe. Holmes, das letzte Wort gehört dir.",
        core: [
          {"Dr. Watson",
           "Als Erzähler schließe ich: Und so wurde ein großer Skandal abgewendet, der das Königreich Böhmen hätte erschüttern können, und die besten Pläne des Mr. Sherlock Holmes wurden vom Witz einer Frau zunichtegemacht. Er pflegte über die Klugheit der Frauen zu spotten — in letzter Zeit höre ich ihn das nicht mehr tun."},
          {"Sherlock Holmes",
           "Und wenn er von Irene Adler spricht oder ihrer Fotografie gedenkt, so geschieht es stets unter dem ehrenvollen Titel: die Frau."},
          {"SL",
           "Und da setzen wir den Punkt. Das war ‚Ein Skandal in Böhmen' — sauber durchgespielt, vom ersten Pfund bis zur letzten Pointe. Stark gespielt, ihr beiden."}
        ]
      }
    ]
  end
end

# Session 1 — D'Artagnans Reise + Triple-Duell
# Quelle: Dumas, Les trois mousquetaires (1844), Kapitel 1-5 (gemeinfrei).
defmodule MusketiereGenerator.S1 do
  def beats do
    [
      %{
        title: "Abreise aus Béarn",
        dm:
          "Wir beginnen im April 1625. D'Artagnan, neunzehn Jahre, der einzige Sohn eines verarmten Gascogner Edelmanns, verlässt das Vaterhaus in der Provinz Béarn. Drei Geschenke vom Vater: ein gelbliches Pferd von vierzehn Jahren, der Familiendegen, und ein Empfehlungsschreiben an M. de Tréville, Capitain der Musketiere des Königs. Ihr Vater ist alter Kriegskamerad von Tréville. D'Artagnan, beschreibe mir, wie du aufbrichst.",
        core: [
          {"D'Artagnan", "Ich packe die Geschenke ein. Brief in den Hemdausschnitt — direkt am Herzen. Degen umgegürtet, ein bisschen zu schwer für meine Gestalt. Mutter weint, Vater nickt nur."},
          {"SL", "Dein Vater: 'D'Artagnan, mein Sohn — verkaufe niemals deinen Degen unter Wert. Duelliere bei jeder Gelegenheit. Die Duelle sind heute verboten, also ist es doppelte Tapferkeit. Trage immer den Hut hoch.'"},
          {"D'Artagnan", "Ich nehme die Worte ernst. Sehr ernst."},
          {"Athos", "Wir hören nur zu — das ist deine Eröffnungs-Szene."},
          {"Porthos", "Wann kommen wir ins Spiel?"},
          {"SL", "In etwa drei Beats. Geduld, Porthos. D'Artagnan reitet jetzt los — Richtung Norden."},
          {"D'Artagnan", "Wenn ich Paris erreiche, werde ich ein Musketier. Spätestens in zwei Wochen."},
          {"Athos", "Ein neunzehnjähriger Gascogner wird in zwei Wochen Musketier? Insight gegen das."},
          {"SL", "Athos, du bist noch nicht in der Szene. Halt deine Insight zurück."}
        ]
      },
      %{
        title: "Meung-sur-Loire — der Mann mit der Narbe",
        dm:
          "Drei Tage später. D'Artagnan reitet durch das kleine Städtchen Meung-sur-Loire. Sein gelbes Pferd ist verschwitzt und zieht jeden Blick auf sich — sehr gelbliche Stute, fast Maultier-Farbe. Vor dem Wirtshaus 'Zum Franc-Meunier' stehen drei Männer und lachen, als D'Artagnan vorbeireitet. D'Artagnan, was tust du?",
        core: [
          {"D'Artagnan", "Ich halte mein Pferd an und schaue sie scharf an."},
          {"SL", "Macht eine Insight-Probe."},
          {"D'Artagnan", "Insight. Vierzehn."},
          {"SL", "Du erkennst — die drei Männer lachen über DICH. Genauer: über dein gelbes Pferd. Einer von ihnen ist anders — älter, gepflegt, eine schmale Narbe an der linken Schläfe."},
          {"D'Artagnan", "Ich steige ab. 'Mein Herr — über was lachen Sie?'"},
          {"SL", "Der Mann mit der Narbe — du kennst seinen Namen noch nicht, später erfährst du: Rochefort. Er antwortet: 'Über das Pferd, junger Herr. Es hat die Farbe einer Butterblume — selten. Aber unstreitig hässlich.'"},
          {"D'Artagnan", "Ich greife zum Degen."},
          {"SL", "Bevor du den Degen ziehst — Initiative."}
        ]
      },
      %{
        title: "Der Hinterhalt von Meung",
        dm:
          "Initiative würfeln. Die drei Männer plus Rochefort haben 18. D'Artagnan würfelt.",
        core: [
          {"D'Artagnan", "Initiative. Acht. Verfehlt — sie sind schneller."},
          {"SL", "Die drei Männer ziehen Knüppel hervor — keine Schwerter, sondern Holzstöcke. Rochefort selbst greift nicht — er steht zurück und beobachtet."},
          {"D'Artagnan", "Ich ziehe trotzdem den Degen — Reckless Attack auf den nächsten."},
          {"SL", "Trefferversuch — du würfelst."},
          {"D'Artagnan", "Mit Reckless-Vorteil: erster Wurf vierzehn, zweiter zweiundzwanzig. Treffer."},
          {"SL", "Schaden — 1d8 + Geschick."},
          {"D'Artagnan", "Sieben Schaden. Der erste Mann taumelt zurück, blutet aus der Schulter."},
          {"SL", "Die anderen zwei greifen dich von hinten. Knüppel-Schlag. Sechs Schaden, dann acht."},
          {"D'Artagnan", "Ich bin auf zwölf von dreißig Hitpoints."},
          {"SL", "Rochefort tritt vor. 'Genug. Junger Mann, ihr seid mutig — aber nicht klug. Lasst eure Faust sinken.'"},
          {"D'Artagnan", "Ich lasse den Degen sinken — atmend, blutend."}
        ]
      },
      %{
        title: "Der gestohlene Brief",
        dm:
          "Rochefort tritt näher, betrachtet euer Wams. Beschreibt mir, was ihr seht.",
        core: [
          {"SL", "Während D'Artagnan abgelenkt ist, hat einer der Männer dein Wams durchwühlt. Der Brief deines Vaters — der Empfehlungsbrief an Tréville — er ist weg."},
          {"D'Artagnan", "Mein BRIEF! Wo ist mein Brief?"},
          {"SL", "Rochefort lächelt — knapp. 'Der Brief ist auf dem Weg zu jemandem, der ihn besser zu schätzen weiß als ihr. Lebt wohl, junger Herr.'"},
          {"D'Artagnan", "Wer SEID ihr?"},
          {"SL", "Rochefort: 'Ein Untertan der Eminenz. Mehr braucht ihr nicht zu wissen.'"},
          {"D'Artagnan", "Insight nochmal. Mit Vorteil. Sechzehn und neunzehn — ich nehme neunzehn."},
          {"SL", "Eminenz — du verstehst: Cardinal Richelieu. Rochefort ist ein Cardinal-Agent. Und in einer Kutsche vor dem Wirtshaus sitzt eine Frau — blond, etwa fünfundzwanzig, blaue Augen, eine kleine Lilien-Brandnarbe auf der linken Schulter, halb verdeckt vom Kleid. Sie schaut dich kurz an — neugierig, nicht ohne Wohlgefallen — und wendet sich ab."},
          {"D'Artagnan", "Wer ist sie?"},
          {"SL", "Du weißt es nicht. Du wirst es später erfahren: Milady de Winter."}
        ]
      },
      %{
        title: "Ankunft in Paris",
        dm:
          "Vier Tage später. D'Artagnan erreicht Paris — er reitet durch das Saint-Antoine-Tor. Der Lärm der Hauptstadt schlägt ihm entgegen. Pferde, Karren, Marktschreier, Glocken. Macht eine Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Vierzehn."},
          {"SL", "Du siehst — drei Musketiere in blau-silbernen Wämsen, Federhüte, am Brunnen lachend. Sie sind das Idealbild dessen, was du werden willst."},
          {"D'Artagnan", "Ich kann nicht stehen bleiben — ich muss zu Tréville."},
          {"SL", "Eine Frau ruft dir nach: 'Junger Herr, wollt ihr ein Quartier?'"},
          {"D'Artagnan", "Wer ist sie?"},
          {"SL", "Madame Bonacieux — eine Vermieterin, etwa dreißig, freundliches Gesicht. Sie hat ein Zimmer im obersten Stock zu vergeben. Du nimmst das Angebot später an — heute willst du erst Tréville besuchen."},
          {"D'Artagnan", "Ich werfe Persuasion — sie soll mir die Richtung zum Hôtel de Tréville zeigen."},
          {"D'Artagnan", "Sechzehn."},
          {"SL", "Sie zeigt dir den Weg. 'Zwei Straßen weiter — das große Tor mit dem königlichen Wappen.'"}
        ]
      },
      %{
        title: "Im Vorhof des Hôtel de Tréville",
        dm:
          "D'Artagnan steht im Vorhof des Hôtel de Tréville. Etwa dreißig Musketiere lungern hier — manche fechten in Pärchen, manche lachen, einer schläft auf einer Bank, mit seinem Hut tief im Gesicht. Es ist eine Art Klub. Beschreibt mir, was D'Artagnan tut.",
        core: [
          {"D'Artagnan", "Ich gehe direkt auf die Treppe zu — Tréville-Audienz."},
          {"SL", "Auf der Treppe stehen zwei Musketiere und sprechen leise. Einer von ihnen ist groß, breit, sehr blau-rot-gelbes Wams, ein Schultergürtel mit Goldbestickung — Porthos."},
          {"Porthos", "Ich rede gerade mit einem anderen Musketier — über meinen neuen Schultergürtel. Es ist sehr eindrucksvoll."},
          {"D'Artagnan", "Ich versuche, vorbei zu kommen — geringe Höflichkeit."},
          {"SL", "Du stößt versehentlich gegen Porthos' Schultergürtel — gerade da, wo die Goldbestickung am dichtesten ist. Macht eine Wahrnehmungs-Probe."},
          {"D'Artagnan", "Wahrnehmung. Sechzehn."},
          {"SL", "Du siehst — die Rückseite des Schultergürtels ist nicht bestickt. Nur die Vorderseite. Das ist ein billiger Trick, das Wams täuscht nur teurer aus. Porthos schämt sich — versucht es zu verbergen."},
          {"Porthos", "WAS habt ihr da gesehen, junger Herr?"},
          {"D'Artagnan", "Ich habe — nichts gesehen."},
          {"Porthos", "Nichts gesehen? Ich glaube, ihr habt etwas gesehen. Wir reden später darüber. Heute mittag, hinter dem Luxembourg, zwölf Uhr."},
          {"D'Artagnan", "Bestätigt. Zwölf Uhr."}
        ]
      },
      %{
        title: "Aramis und das Taschentuch",
        dm:
          "D'Artagnan hetzt weiter zur Treppe — er ist schon zu spät für Tréville. Im nächsten Korridor lehnt ein junger Mann an der Wand — eleganter Mantel, sanfte Augen, ein Taschentuch in der Hand. Er liest. Das ist Aramis.",
        core: [
          {"D'Artagnan", "Ich gehe schnell vorbei — Aramis legt das Taschentuch zur Seite, um in seinem Buch zu blättern."},
          {"SL", "Genau in dem Moment — D'Artagnan stößt mit dem Fuß gegen das Taschentuch. Es fällt zu Boden. Auf das Taschentuch ist ein Wappen gestickt — du erkennst es: das Wappen einer Hofdame. Bestimmt nicht das Taschentuch eines Musketiers, der gerade ein Priesterstudium plant."},
          {"D'Artagnan", "Ich hebe das Taschentuch auf — ich will ihm helfen."},
          {"Aramis", "Mein Herr — bitte. Lasst das Taschentuch liegen. Wer es aufhebt, wird es behalten müssen. Ich kann es nicht haben."},
          {"D'Artagnan", "Aber — wem gehört es?"},
          {"Aramis", "Einer Dame. Genug gesagt. Bitte legt es zurück."},
          {"SL", "Andere Musketiere haben es gesehen — sie kichern. Aramis ist sichtlich in Verlegenheit."},
          {"D'Artagnan", "Ich verstehe nicht — ich wollte nur helfen."},
          {"Aramis", "Junger Herr — heute mittag, ein Uhr. Hinter dem Luxembourg-Garten. Ich werde euch helfen, die feinen Manieren zu verstehen."},
          {"D'Artagnan", "Bestätigt. Ein Uhr."}
        ]
      },
      %{
        title: "Audienz bei Tréville",
        dm:
          "D'Artagnan endlich im Büro von M. de Tréville. Tréville ist sechzig, grauhaarig, in voller blauer Musketier-Uniform. Auf dem Schreibtisch: ein Stapel Papiere. Tréville ist gerade in einer schlechten Laune — er hat eben Athos, Porthos und Aramis gerügt für eine Schlägerei mit Cardinal-Wachen vor zwei Tagen.",
        core: [
          {"SL", "Tréville: 'Welcher von euch — wo ist der junge Mann aus Béarn, dessen Vater mir schreibt?'"},
          {"D'Artagnan", "Ich, Capitain. Ich, D'Artagnan, Sohn von Pierre Darvis-D'Artagnan."},
          {"SL", "Tréville: 'Pierre. Mein alter Kamerad. Habt ihr seinen Brief?'"},
          {"D'Artagnan", "Capitain — der Brief wurde mir gestohlen. In Meung-sur-Loire. Von einem Mann mit einer Narbe an der Schläfe."},
          {"SL", "Tréville reagiert — fast unmerklich, aber du siehst es. Persuasion-Probe."},
          {"D'Artagnan", "Persuasion. Achtzehn."},
          {"SL", "Tréville: 'Ein Mann mit einer Narbe an der Schläfe? Hochgewachsen, etwa vierzig? Schmaler Mund?'"},
          {"D'Artagnan", "Genau."},
          {"SL", "Tréville: 'Bei den Heiligen. Das ist Rochefort — Cardinal Richelieus rechte Hand. Wenn er den Brief hat, wisst ihr — der Cardinal weiß auch, dass ihr in Paris seid. Ihr seid noch nicht mal eingewölbt, und schon im Spiel.'"},
          {"D'Artagnan", "Ich will Musketier werden, Capitain. Aufnehmen Sie mich."},
          {"SL", "Tréville: 'Junger Herr — Musketier wird man nicht. Musketier wird man nach zwei Jahren Garde-Dienst, zwei Schlachten, drei Empfehlungen. Heute kann ich nichts für euch tun. Wir werden sehen. Geht für jetzt — und bleibt aus Ärger.'"}
        ]
      },
      %{
        title: "Athos und der Stoß",
        dm:
          "D'Artagnan verlässt Trévilles Büro frustriert. Auf der Treppe — eine Hindernis. Ein Musketier steht da, eine Hand auf der Schulter, blass, schwarzhaarig, mittlere Statur, eine deutliche Verletzung am rechten Arm. Das ist Athos.",
        core: [
          {"D'Artagnan", "Ich renne hektisch los — Wahrnehmung: zehn. Ich sehe ihn nicht."},
          {"SL", "Du stößt ihn — schwer. Direkt gegen seine verletzte Schulter. Er taumelt zur Wand, sein Wams färbt sich rot."},
          {"Athos", "Ich werfe Constitution-Save. Vierzehn. Ich bleibe stehen, halte mein Gesicht."},
          {"SL", "Athos: 'Mein Herr — wartet einen Moment.'"},
          {"D'Artagnan", "Verzeiht — ich war eilig — bitte, ich wollte nicht — "},
          {"Athos", "Ich bin Athos. Mein Herr, ihr habt mir gerade einen Stoß gegen eine Wunde gegeben. Ich werde euch nicht beleidigen — ihr scheint jung. Aber ich werde euch ein Duell anbieten müssen. Eine Frage der Ehre."},
          {"D'Artagnan", "Bestätigt. Wo? Wann?"},
          {"Athos", "Hinter dem Luxembourg. Zwölf Uhr."},
          {"D'Artagnan", "Zwölf — verzeiht — Porthos hat mir zwölf Uhr arrangiert."},
          {"Athos", "Dann zwölf Uhr fünfzehn."},
          {"D'Artagnan", "Aramis hat mir EIN Uhr arrangiert."},
          {"Athos", "Dann werden wir alle nacheinander mit euch fechten. Ein interessanter Tag."}
        ]
      },
      %{
        title: "Hinter dem Luxembourg — zwölf Uhr",
        dm:
          "D'Artagnan steht hinter dem Kloster der Karmeliten am Luxembourg. Sein Magen knurrt — er hat nicht zu Mittag gegessen. Porthos und Aramis kommen zusammen, dann Athos. Sie sind erstaunt.",
        core: [
          {"Athos", "Mein Herr — ich sehe meine zwei Sekundanten kommen, Porthos und Aramis. Aber das sind eure Duell-Partner gleichermaßen?"},
          {"D'Artagnan", "Genau. Ich habe drei Duelle arrangiert — alle innerhalb von ein paar Minuten."},
          {"Porthos", "Drei Duelle hintereinander? Mit DEM hier? Er ist halb so groß wie ich."},
          {"D'Artagnan", "Ich bin nur halb so groß wie ihr — aber meine Klinge ist GANZ so lang."},
          {"Aramis", "Gascogner — typisch."},
          {"Athos", "Mein Herr, ich bin der erste. Wenn ihr danach noch lebt, übernimmt Porthos. Dann Aramis."},
          {"SL", "Initiative bitte. D'Artagnan vs Athos."},
          {"D'Artagnan", "Initiative. Achtzehn."},
          {"Athos", "Initiative. Sechzehn."},
          {"SL", "D'Artagnan geht zuerst."}
        ]
      },
      %{
        title: "Cardinal-Wachen kommen",
        dm:
          "Bevor die Klingen sich kreuzen — Hufschlag von der Straßenseite. Fünf Cardinal-Wachen in roten Uniformen erscheinen — mit Jussac an der Spitze. Macht eine Wahrnehmungs-Probe.",
        core: [
          {"D'Artagnan", "Wahrnehmung. Sechzehn."},
          {"SL", "Du siehst — Rochefort steht in der Ferne, beobachtet. Cardinal-Wachen haben Wind von dem Duell bekommen — Duellieren ist offiziell verboten. Sie wollen die drei Musketiere verhaften."},
          {"SL", "Jussac (Cardinal-Wache): 'Ihr, Musketiere — ihr seid hiermit unter Arrest wegen verbotenen Duells.'"},
          {"Athos", "Cardinal-Wachen. Schon wieder."},
          {"Porthos", "Wir sollten sie nicht arrestieren lassen."},
          {"Aramis", "Wir sind drei. Sie sind fünf."},
          {"D'Artagnan", "Wir sind VIER."},
          {"SL", "Athos sieht dich an — überrascht."},
          {"Athos", "Junger Herr — ihr seid nicht Musketier. Ihr habt keinen Vertrag mit uns."},
          {"D'Artagnan", "Ich habe einen Vertrag — als Gascogner. Mit der Königlichen Sache. Ich kämpfe mit euch."},
          {"Athos", "Bei den Heiligen. Schön. Ihr seid in unserer Mitte."},
          {"SL", "Initiative für alle. Vier vs fünf. Macht weiter."}
        ]
      },
      %{
        title: "Kampf gegen Jussac und Co.",
        dm:
          "Initiative-Reihe würfeln.",
        core: [
          {"D'Artagnan", "Initiative. Neunzehn."},
          {"Athos", "Initiative. Fünfzehn."},
          {"Porthos", "Initiative. Zwölf."},
          {"Aramis", "Initiative. Vierzehn."},
          {"SL", "Cardinal-Wachen-Gruppe: dreizehn."},
          {"SL", "Reihenfolge: D'Artagnan, Athos, Aramis, Wachen, Porthos."},
          {"D'Artagnan", "Ich greife Jussac selbst an. Reckless Attack. Erster Wurf: einundzwanzig. Zweiter: achtzehn. Treffer."},
          {"SL", "Schaden — 1d8 + Geschick plus Sneak-Attack als Swashbuckler."},
          {"D'Artagnan", "Acht plus sechs Sneak-Attack — vierzehn Schaden."},
          {"SL", "Jussac taumelt. Du hast einen erfahrenen Cardinal-Soldaten erschüttert. Er knurrt."},
          {"Athos", "Trefferversuch gegen Cardinal-Wache zwei. Mit großem Schwert. Neunzehn — Treffer. Zehn Schaden."},
          {"Aramis", "Sacred Flame als Cleric — Reflex-Save für Wache drei."},
          {"SL", "Wache drei verfehlt — acht Strahlenschaden."},
          {"SL", "Wachen reagieren — Wache vier greift Aramis an. Trefferversuch zwölf — verfehlt. Wache fünf greift Porthos. Sechzehn — Treffer, sieben Schaden."},
          {"Porthos", "Reckless Attack auf Wache fünf. Erster Wurf: zweiundzwanzig. Treffer. Zwölf Schaden. Er fällt."}
        ]
      },
      %{
        title: "Kampf-Ende",
        dm:
          "Runde zwei. Jussac ist noch auf den Beinen, schwer atmend.",
        core: [
          {"D'Artagnan", "Reckless gegen Jussac. Treffer: zwanzig. Sneak-Attack: sechs. Schaden: dreizehn."},
          {"SL", "Jussac fällt. Du hast den Anführer der Cardinal-Wachen besiegt."},
          {"Athos", "Trefferversuch gegen Wache zwei nochmal. Vierundzwanzig. Schaden zwölf."},
          {"SL", "Wache zwei fällt."},
          {"Aramis", "Spiritual Weapon — Wache drei. Trefferversuch: siebzehn — Treffer. Sechs Schaden."},
          {"SL", "Wache drei fällt."},
          {"Porthos", "Wache vier. Reckless. Achtzehn — Treffer. Acht Schaden."},
          {"SL", "Wache vier flieht. Letzte Wache sieht die Lage, wirft den Degen, ergibt sich."},
          {"SL", "Vier von fünf besiegt. Eine ergibt sich. Vier Musketiere — pardon, drei Musketiere plus D'Artagnan — sind die Sieger."},
          {"Athos", "D'Artagnan — ihr habt euch ehrenhaft geschlagen."},
          {"Porthos", "Ihr seid jünger, als ich dachte. Aber mit Klinge — beachtlich."},
          {"Aramis", "Eure Streitlust ist gascognisch. Eure Treffsicherheit ist erstaunlich."}
        ]
      },
      %{
        title: "Im Wirtshaus 'Pinienzapfen'",
        dm:
          "Nach dem Kampf — vier Männer ziehen ins Wirtshaus 'Pinienzapfen'. Sie bestellen Wein, Brot, Käse. Tréville ist noch nicht informiert. D'Artagnan ist erschöpft aber glücklich. Atmosphäre — drei Musketiere und der junge Gascogner.",
        core: [
          {"Athos", "Ich gieße den Wein. Es ist Anjou — eine gute Wahl bei diesem Wetter."},
          {"Porthos", "Mein neuer Schultergürtel hat tatsächlich einen Bestickungs-Mangel auf der Rückseite. Ich gebe es zu."},
          {"Aramis", "Mein Taschentuch — ich gebe es D'Artagnan zur Aufbewahrung. Die Dame hat geschrieben, sie würde es zurückwollen."},
          {"D'Artagnan", "Ich nehme es ehrenvoll."},
          {"Athos", "Mein Wunde-Druck ist abgenommen. Aramis, du hast Healing Word benutzt?"},
          {"Aramis", "Acht Hitpoints — ich tu, was ich kann."},
          {"D'Artagnan", "Gentlemen, ich… ich möchte sagen, dass ich mich heute zum ersten Mal in Paris zugehörig fühle."},
          {"Athos", "Ihr seid einer von uns. Vorläufig."},
          {"Porthos", "Drei Duelle in zwei Stunden — und du lebst noch. Das ist mehr, als die meisten von uns am ersten Tag erreicht haben."},
          {"Aramis", "Auf D'Artagnan."},
          {"Athos", "Auf D'Artagnan."},
          {"Porthos", "Auf D'Artagnan."},
          {"D'Artagnan", "Auf… auf alle von euch."},
          {"SL", "Athos hebt sein Glas. 'Einer für alle — alle für einen.' Sie trinken."}
        ]
      },
      %{
        title: "Tréville hört davon",
        dm:
          "Eine Stunde später — ein Bote tritt ins Wirtshaus. Eine Nachricht von Tréville. Vier Musketiere — pardon, drei Musketiere und D'Artagnan — werden zum Capitain gerufen.",
        core: [
          {"SL", "Bote: 'Capitain de Tréville verlangt, dass ihr alle vier sofort kommt.'"},
          {"D'Artagnan", "ALLE VIER?"},
          {"SL", "Genau. Tréville hat gehört, was passiert ist."},
          {"Athos", "Wir gehen."},
          {"SL", "Im Tréville-Büro — Tréville ist in einer interessanten Stimmung. Er weiß: Cardinal-Wachen geschlagen, Jussac verletzt, fünf Wachen besiegt. Aber er weiß auch: das Duellverbot wurde gebrochen."},
          {"SL", "Tréville: 'Mein lieber D'Artagnan. Ihr habt heute viel getan. Drei Duelle arrangiert. Fünf Cardinal-Wachen besiegt. Jussac verletzt. Und das alles, bevor ihr offiziell Mitglied der Garde seid.'"},
          {"D'Artagnan", "Capitain, ich kann erklären — "},
          {"SL", "Tréville: 'Erklärt nichts. Ich werde euch in die Garde von M. des Essarts aufnehmen — das ist eine Schwesterkompanie der Musketiere. Ihr werdet zwei Jahre dort dienen, dann erwägen wir Musketier-Aufnahme.'"},
          {"D'Artagnan", "Capitain — danke. Ich werde euer Vertrauen nicht enttäuschen."}
        ]
      },
      %{
        title: "Der König hört davon",
        dm:
          "Eine Woche später. Tréville hat den vier eine königliche Audienz arrangiert. Sie stehen vor Louis XIII — neunzehn, schmächtig, eher schüchtern. Der König will den jungen Gascogner kennen lernen, der seine Wachen geschlagen hat.",
        core: [
          {"SL", "Louis XIII: 'Capitain Tréville, das ist der Gascogner?'"},
          {"SL", "Tréville: 'Sire, das ist D'Artagnan. Sohn eines alten Kameraden.'"},
          {"SL", "Louis XIII: 'Junger Herr — Cardinal Richelieu wird euch hassen. Das gefällt mir.'"},
          {"D'Artagnan", "Sire, ich diene dem König — nicht dem Cardinal."},
          {"SL", "Louis XIII lächelt — knapp. 'Eine gute Aussage. Athos, Porthos, Aramis — pflegt diesen Jungen. Ich werde euch im Auge behalten.'"},
          {"D'Artagnan", "Mein König."},
          {"Athos", "Sire."},
          {"Porthos", "Sire."},
          {"Aramis", "Sire."},
          {"SL", "Die Audienz endet. Vier verlassen den Thronsaal — D'Artagnan ist offiziell in der Garde, hat den König getroffen, hat drei beste Freunde gewonnen."}
        ]
      },
      %{
        title: "Quartier bei Bonacieux",
        dm:
          "Ein paar Tage später. D'Artagnan zieht offiziell bei Madame Bonacieux ein. Sie hat ein Zimmer im obersten Stock — schmal, aber sauber. Madame Bonacieux ist verheiratet — mit dem Stadtkaufmann M. Bonacieux, einem dicken, missgünstigen, kleinen Mann. Du wirst sie selten allein sehen, aber wenn doch — sie ist freundlich. Sehr freundlich.",
        core: [
          {"SL", "Madame Bonacieux: 'Mein Herr — willkommen. Ihr werdet sehen, wir sind ruhige Mieter. Mein Mann ist tags meist im Geschäft.'"},
          {"D'Artagnan", "Persuasion. Mit Vorteil — sie hat schon Interesse gezeigt. Achtzehn."},
          {"SL", "Madame Bonacieux lächelt. 'Mein Herr, ihr seid charmant. Vielleicht plaudert ihr später mit mir — wenn mein Mann unterwegs ist.'"},
          {"D'Artagnan", "Ich plaudere gerne."},
          {"SL", "Während ihr euch einrichtet — ihr findet einen Stein lockerer im Boden eures Zimmers. Macht eine Wahrnehmungs-Probe."},
          {"D'Artagnan", "Wahrnehmung. Siebzehn."},
          {"SL", "Du kannst — wenn du den Stein hebst — durch eine kleine Lücke ins darunter liegende Zimmer sehen. Das Zimmer der Bonacieux. Du beschließt: das ist eine Information für später."},
          {"D'Artagnan", "Ich notiere mir das. Mental."}
        ]
      },
      %{
        title: "Erste Cardinal-Wachen-Patrouille",
        dm:
          "Nach drei Wochen Garde-Dienst — D'Artagnan ist auf erste Patrouille. Er begleitet einen erfahrenen Garde-Soldaten Boisrenard durch die Rue Vieux-Colombier. Es ist Abend, Nebel.",
        core: [
          {"SL", "Boisrenard: 'D'Artagnan, mein Junge — pass auf die Cardinal-Wachen auf. Sie haben uns auf dem Kieker, seit ihr Jussac verletzt habt.'"},
          {"D'Artagnan", "Ich war es nicht alleine — wir waren vier."},
          {"SL", "Boisrenard: 'Sie wissen genau, wer der Hauptdarsteller war. Du, D'Artagnan, bist jetzt eine Markierung in Richelieus Augen.'"},
          {"SL", "Macht eine Wahrnehmungs-Probe."},
          {"D'Artagnan", "Wahrnehmung. Vierzehn."},
          {"SL", "Hinter einem Haus — zwei Schatten. Cardinal-Wachen-Uniformen. Sie beobachten dich."},
          {"D'Artagnan", "Boisrenard — sehen Sie sie auch?"},
          {"SL", "Boisrenard: 'Ja. Sie folgen euch. Geht ruhig weiter — keine Reaktion. Wir gehen zurück zum Hôtel.'"},
          {"D'Artagnan", "Ich gehe ruhig — aber meine Hand auf dem Degenknauf."}
        ]
      },
      %{
        title: "Athos' Geheimnis-Hinweis",
        dm:
          "Eine Woche später. D'Artagnan trinkt mit Athos in einem ruhigen Wirtshaus. Athos ist tief im Wein — er trinkt heute mehr als sonst. Macht eine Insight-Probe.",
        core: [
          {"D'Artagnan", "Insight. Mit Vorteil — wir sind enge Freunde. Neunzehn und einundzwanzig — ich nehme einundzwanzig."},
          {"SL", "Athos ist sehr ruhig. Er schaut in seinen Wein, drückt die Stirn mit der Hand."},
          {"D'Artagnan", "Athos — was bedrückt dich?"},
          {"Athos", "D'Artagnan — ich werde dir eine Geschichte erzählen. Aber nicht heute. Heute trinke ich. Heute denke ich an eine Frau, die ich einmal liebte."},
          {"D'Artagnan", "Eine Frau?"},
          {"Athos", "Ja. Sie hatte ein Brandzeichen auf der Schulter — eine Lilie. Das Brandzeichen von Verbrechern. Aber sie war meine Frau. Wir lebten in einem Schloss in Berry. Ich war zwanzig. Sie war achtzehn — oder so dachte ich."},
          {"D'Artagnan", "Athos, das klingt schwer — "},
          {"Athos", "Eines Tages — beim Jagdausflug — sie fiel vom Pferd. Ihr Kleid wurde aufgerissen. Ich sah das Brandzeichen. Eine Lilie. Sie war eine Verbrecherin. Eine Diebin — vielleicht eine Mörderin. Ich — ich tat, was ein Edelmann tut: ich hängte sie an einem Baum. Ich dachte, sie wäre tot."},
          {"D'Artagnan", "Du… du hast sie GEHÄNGT?"},
          {"Athos", "Junger Mann — heute trinke ich. Morgen reden wir nicht mehr davon. Verstanden?"},
          {"D'Artagnan", "Verstanden."}
        ]
      },
      %{
        title: "Begegnung mit Constance — heimlich",
        dm:
          "Am nächsten Tag — D'Artagnan ist in seinem Zimmer. Durch die Spalte im Boden hört er Stimmen unten — Madame Bonacieux mit einer fremden Stimme. Sie wirkt aufgeregt.",
        core: [
          {"SL", "Macht eine Wahrnehmungs-Probe — du willst lauschen."},
          {"D'Artagnan", "Wahrnehmung. Achtzehn."},
          {"SL", "Du hörst — Madame Bonacieux: 'Aber das ist gefährlich. Wenn Richelieu erfährt — '. Eine zweite Stimme, weiblich, sehr leise: 'Die Königin braucht Hilfe. Es geht um die Anhänger. Der Cardinal will den König gegen Anne aufhetzen.'"},
          {"D'Artagnan", "Die Königin braucht Hilfe?"},
          {"SL", "Madame Bonacieux: 'Ich werde tun, was ich kann. Aber mein Mann darf nichts wissen — er ist ein Cardinal-Freund.'"},
          {"SL", "Die Stimmen verstummen. Die zweite Dame geht."},
          {"D'Artagnan", "Ich werde Madame Bonacieux später ansprechen — wenn ich allein mit ihr sprechen kann."},
          {"SL", "Du sehst durch die Spalte — sie schaut nach oben. Sie weiß, dass du hörst. Sie nickt — ein winziges Nicken. Sie wird dich um Hilfe bitten — bald."}
        ]
      },
      %{
        title: "Cliffhanger — die Königin braucht Hilfe",
        dm:
          "Es ist Spätabend. D'Artagnan sitzt am Fenster, schaut über die Pariser Dächer. Athos, Porthos und Aramis sitzen bei ihm — sie haben sich heute zum Wein eingefunden.",
        core: [
          {"D'Artagnan", "Brüder — ich habe etwas Wichtiges zu erzählen. Madame Bonacieux — die Königin hat ein Problem."},
          {"Athos", "Welches Problem?"},
          {"D'Artagnan", "Anhänger. Die Königin hat — ich weiß nicht genau — Anhänger verschenkt. Cardinal Richelieu will sie verlangen. Wenn die Königin sie nicht hat — Skandal."},
          {"Aramis", "Anhänger — du meinst die zwölf Diamant-Anhänger?"},
          {"D'Artagnan", "Möglich. Du weißt davon?"},
          {"Aramis", "Eine Hofdame — keine Namen — hat mir gegenüber Anspielungen gemacht. Es scheint, die Königin hat sie an einen Engländer geschickt. Sehr inoffiziell."},
          {"Porthos", "Englisch? Das wird kompliziert. England und Frankreich — Kalter Krieg."},
          {"Athos", "Wenn die Königin Hilfe braucht, helfen wir."},
          {"D'Artagnan", "Madame Bonacieux wird mich morgen oder übermorgen ansprechen. Ich melde mich, sobald ich was Konkretes weiß."},
          {"SL", "Session-Ende. XP — 800 pro Charakter. Inspiration für D'Artagnan: die Triple-Duell-Performance war Gold."},
          {"D'Artagnan", "Ich nehme Inspiration. Spare sie für etwas Hartes."},
          {"Athos", "Auf nächste Session."},
          {"Porthos", "Auf den Cardinal — möge er sich verschlucken."},
          {"Aramis", "Sicut dixit dominus. Amen."}
        ]
      }
    ]
  end
end

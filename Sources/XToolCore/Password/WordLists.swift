/// Word lists for the password rules. Fixed in the app: nothing is downloaded, nothing changes.
enum WordLists {
    /// Frequently used passwords (German and international), lower case.
    static let commonPasswords: Set<String> = [
        "123456", "1234567", "12345678", "123456789", "1234567890", "12345678910", "123123", "123321", "111111", "000000",
        "654321", "666666", "696969", "121212", "112233", "password", "passwort", "passwort1", "kennwort", "geheim", "geheimnis",
        "qwerty", "qwertz", "qwertzuiop", "qwertyuiop", "asdfgh", "asdfghjkl", "yxcvbnm", "abc123", "abcdef", "abcdefg", "abcdefgh",
        "letmein", "welcome", "willkommen", "admin", "administrator", "root", "login", "master", "masterpasswort", "masterpassword",
        "iloveyou", "ichliebedich", "liebe", "schatz", "schatzi", "hallo", "hallihallo", "hallo123", "dragon", "monkey", "football",
        "fussball", "baseball", "superman", "batman", "pokemon", "starwars", "sunshine", "princess", "prinzessin", "shadow", "michael",
        "thomas", "andreas", "stefan", "alexander", "daniel", "christian", "nicole", "sabine", "jessica", "ashley", "charlie", "jordan",
        "hunter", "killer", "trustno1", "freedom", "whatever", "computer", "internet", "samsung", "google", "apple", "macbook", "iphone",
        "summer", "winter", "spring", "autumn", "sommer", "herbst", "fruehling", "frühling", "januar", "februar", "maerz", "märz", "april",
        "juni", "juli", "august", "september", "oktober", "november", "dezember", "montag", "dienstag", "mittwoch", "donnerstag",
        "freitag", "samstag", "sonntag", "deutschland", "germany", "schweiz", "switzerland", "oesterreich", "österreich", "berlin",
        "hamburg", "muenchen", "münchen", "zuerich", "zürich", "wien", "bayern", "dortmund", "schalke", "ficken", "arschloch", "scheisse",
        "mama", "papa", "familie", "zuhause", "sicherheit", "sicher", "tresor", "xtool", "test", "test123", "testtest", "changeme", "default",
        "guest", "gast", "benutzer", "user", "secret", "access", "zugang", "start", "start123", "ninja", "mustang", "corvette", "ferrari",
        "porsche", "mercedes", "volkswagen", "harley", "matrix", "soccer", "hockey", "jennifer", "buster", "tigger", "pepper", "ginger",
    ]

    /// Everyday words that make a password guessable when strung together.
    static let commonWords: Set<String> = [
        "der", "die", "das", "und", "ist", "ich", "bin", "mein", "meine", "dein", "deine", "sein", "seine", "ein", "eine", "nicht", "mit",
        "auf", "aus", "von", "für", "fuer", "hat", "haus", "hund", "katze", "auto", "kind", "kinder", "frau", "mann", "name", "tag", "jahr",
        "zeit", "welt", "leben", "arbeit", "firma", "geld", "bank", "konto", "mail", "email", "handy", "the", "and", "you", "love", "house",
        "dog", "cat", "car", "work", "money", "home", "life", "world", "pass", "word", "key", "lock", "safe", "secure", "super", "best",
        "gut", "toll", "neu", "alt", "gross", "groß", "klein", "rot", "blau", "gelb", "grün", "gruen", "schwarz", "weiss", "weiß", "sonne",
        "mond", "stern", "blume", "baum", "wasser", "feuer", "erde", "luft", "red", "blue", "green", "black", "white", "sun", "moon", "star",
    ]

    /// Suggestions are built from these: simple German words without umlauts, easy to type on any keyboard.
    static let passphraseWords: [String] = [
        "Abend", "Acker", "Adler", "Ahorn", "Akte", "Alge", "Alpen", "Ampel", "Amsel", "Anker", "Antenne", "Apfel", "Arena", "Armband", "Asche", "Ast",
        "Atlas", "Atem", "Auge", "Ausflug", "Avocado", "Backe", "Bagger", "Bahnhof", "Balkon", "Ballon", "Banane", "Bank", "Bart", "Basilikum", "Batterie", "Bauer",
        "Becher", "Beere", "Berg", "Besen", "Beton", "Biene", "Birne", "Blatt", "Bleistift", "Blitz", "Blume", "Bluse", "Boden", "Bogen", "Bohne", "Boje",
        "Bonbon", "Boot", "Brezel", "Brief", "Brille", "Brot", "Brunnen", "Buch", "Bucht", "Burg", "Butter", "Cello", "Chor", "Clown", "Dach", "Dackel",
        "Dampf", "Dattel", "Daumen", "Decke", "Delfin", "Deich", "Dose", "Drache", "Draht", "Dschungel", "Eiche", "Eimer", "Eisberg", "Elch", "Elefant",
        "Engel", "Ente", "Erbse", "Esche", "Esel", "Eule", "Fabrik", "Fackel", "Faden", "Fahne", "Falke", "Farbe", "Farn", "Fass", "Feder", "Fee",
        "Feige", "Feld", "Felsen", "Fenster", "Ferien", "Fernrohr", "Fest", "Fichte", "Filz", "Fisch", "Flamme", "Flasche", "Flocke", "Floh", "Floss", "Flosse",
        "Fluss", "Fohlen", "Forelle", "Foto", "Frosch", "Fuchs", "Gabel", "Galaxie", "Gans", "Garten", "Gazelle", "Gecko", "Geige", "Geysir", "Giraffe",
        "Gitarre", "Glas", "Globus", "Glocke", "Gold", "Gondel", "Gras", "Grille", "Gurke", "Gummi", "Hafen", "Hafer", "Hagel", "Hahn", "Hai", "Halm",
        "Hammer", "Hamster", "Handschuh", "Harfe", "Hase", "Haube", "Hecht", "Hecke", "Heft", "Heide", "Helm", "Hemd", "Herd", "Hering", "Heu", "Himbeere",
        "Hirsch", "Hobel", "Holz", "Honig", "Horizont", "Hummel", "Hummer", "Hut", "Igel", "Imker", "Insel", "Jacke", "Jaguar", "Joghurt", "Jolle",
        "Kaffee", "Kaktus", "Kamel", "Kamin", "Kamm", "Kanal", "Kanu", "Kapelle", "Karotte", "Karte", "Kastanie", "Kater", "Kegel", "Keks", "Kelle", "Kerze",
        "Kessel", "Kette", "Kiefer", "Kiesel", "Kirsche", "Kissen", "Kiste", "Kiwi", "Klavier", "Klee", "Knopf", "Koala", "Kobold", "Koch", "Koffer", "Kohl",
        "Kolibri", "Komet", "Kompass", "Koralle", "Korb", "Korken", "Kran", "Kranich", "Krebs", "Kreide", "Kreis", "Krone", "Krug", "Kuchen", "Kuckuck", "Kugel",
        "Kuppel", "Kurbel", "Lachs", "Lager", "Lama", "Lampe", "Laterne", "Laub", "Lavendel", "Lawine", "Leder", "Leiter", "Lerche", "Leuchte", "Libelle", "Lied",
        "Lilie", "Limette", "Linde", "Linse", "Lippe", "Locke", "Lotse", "Lotus", "Luchs", "Lupe", "Magnet", "Mais", "Mandel", "Mango", "Mantel", "Marder",
        "Marmor", "Maske", "Matrose", "Mauer", "Maus", "Meer", "Meise", "Melone", "Mikrofon", "Minze", "Mixer", "Mohn", "Mond", "Moos", "Motor", "Mosaik",
        "Muschel", "Museum", "Nadel", "Nagel", "Narzisse", "Nebel", "Nelke", "Nest", "Netz", "Nudel", "Nuss", "Oase", "Obst", "Ofen", "Olive",
        "Oper", "Orange", "Orchidee", "Orgel", "Otter", "Ozean", "Paddel", "Palme", "Panda", "Papier", "Pappel", "Paprika", "Park", "Pedal", "Pegel", "Pelikan",
        "Perle", "Pfad", "Pfanne", "Pfeffer", "Pfeil", "Pferd", "Pfirsich", "Pflaume", "Pinguin", "Pinsel", "Pilz", "Pirat", "Pizza", "Planet", "Plakat", "Pollen",
        "Pony", "Posaune", "Puppe", "Quelle", "Qualle", "Quark", "Rabe", "Radio", "Rakete", "Rampe", "Rasen", "Raupe", "Regal", "Regen", "Reh", "Reis",
        "Rettich", "Riegel", "Riese", "Ring", "Robbe", "Rock", "Roggen", "Roller", "Rose", "Rosine", "Rucksack", "Ruder", "Safran", "Saft", "Salat", "Salbei",
        "Salz", "Samen", "Sand", "Sattel", "Schaf", "Schal", "Schale", "Schatten", "Schaufel", "Schiff", "Schild", "Schlitten", "Schloss", "Schnecke", "Schnee", "Schraube",
        "Schuh", "Schwan", "Schwamm", "See", "Segel", "Seide", "Seife", "Seil", "Senf", "Sessel", "Sichel", "Silber", "Skizze", "Socke", "Sofa", "Sonne",
        "Spargel", "Spatz", "Specht", "Spiegel", "Spinat", "Spinne", "Stall", "Stamm", "Stein", "Stempel", "Stern", "Stiefel", "Storch", "Strand", "Strauch", "Strom",
        "Stuhl", "Sturm", "Tafel", "Tanne", "Tasche", "Tasse", "Taube", "Teich", "Teller", "Tempel", "Teppich", "Thymian", "Tiger", "Tinte", "Tisch", "Toast",
        "Tomate", "Topf", "Trommel", "Trompete", "Truhe", "Tulpe", "Turm", "Ufer", "Uhr", "Ulme", "Vase", "Veilchen", "Ventil", "Vogel", "Vulkan", "Waage",
        "Wachs", "Wald", "Walnuss", "Walross", "Wanne", "Wecker", "Weide", "Wein", "Weizen", "Welle", "Wiese", "Wimpel", "Wind", "Wolf", "Wolke", "Wolle",
        "Abzweig", "Amboss", "Anorak", "Bambus", "Bassin", "Beutel", "Biber", "Bison", "Bogenschuss", "Brombeere", "Buche", "Bussard", "Dattelpalme", "Delta", "Dolch", "Dorf",
        "Efeu", "Eisvogel", "Erdnuss", "Fasan", "Fenchel", "Fjord", "Forst", "Fregatte", "Gerste", "Gletscher", "Glut", "Granit", "Hagebutte", "Hafenkran", "Heuschrecke", "Holunder",
        "Jasmin", "Kajak", "Kakao", "Kamille", "Kanarie", "Kapitel", "Karawane", "Kerbel", "Kirche", "Klippe", "Kokos", "Krokus", "Kupfer", "Lagune", "Lehm", "Leuchtturm",
        "Linsen", "Lorbeer", "Marille", "Moschus", "Nashorn", "Neffe", "Nordlicht", "Orkan", "Papagei", "Passat", "Pavian", "Pfau", "Quitte", "Rentier", "Riff", "Sanddorn",
        "Schilf", "Seerose", "Sonnenblume", "Steppe", "Tundra", "Uhu", "Wacholder", "Wasserfall", "Wiesel", "Zander", "Zeppelin", "Ziegel",
        "Wurzel", "Zahnrad", "Zange", "Zebra", "Zeder", "Zelt", "Ziege", "Zimt", "Zirkus", "Zitrone", "Zucker", "Zweig", "Zwiebel", "Zypresse", "Zither", "Zaun",
    ]
}

#import "info.typ" as info
#import "@preview/algorithmic:0.1.0"
#import algorithmic: algorithm
#import "@preview/bob-draw:0.1.0": render

#set text(lang: "de", font: "Arial", size: 10pt, )
#let title = [Shared Everything - Eine andere Architektur für Datenbanken]

#set page(header: [
  #info.name #h(1fr) #title #h(1fr) 2024
], footer: [
  #h(1fr) #counter(page).display("1/1", both: true) #h(1fr)
], margin: (x: 2.5cm, y: 2cm))

#set document(title: title, author: info.name, date: datetime(year: 2024, month: 5, day: 17))
#set quote(block: true)
#set heading(numbering: "1.1")
#show heading: it => [
  #set par(leading: 0.65em)
  #block(it, below: 1em)
]
#show figure: it => [
  #set par(leading: 0.65em)
  #it
]

#v(30%)
#align(center, 
[#text(17pt)[
  *#title*
]

#text(13pt)[
  *Effizienz von In-Memory-Datenbanken steigern*
]])

#let bll = true

#set par(leading: 0.5em)
#align(center)[
#info.project \
2024 \
#info.name
]

#set block(spacing: 2em)
#set par(leading: 1.5em)
#pagebreak()

#text(15pt)[
  *Projektüberblick*
]
#set par(justify: true)

Ziel dieses Projektes ist es die weit verbreitete Shared Nothing Architektur, die in vielen Computersystemen genutzt wird, kritisch im Gebiet der In-Memory-Datenbanken zu betrachten.
Hierbei steht besonders die dazu gegenteilige Shared Everything Architektur im Fokus, in der ich eine Datenbank implementiere.
Diese Datenbank ist eine Alternative zu aktuell verbreiteten Datenbanken und wird mit diesen verglichen, um die Charakteristiken der Architekturen zu ermitteln.

Für den Vergleich im Bereich der In-Memory-Datenbanken habe ich den Industriestandard Redis und die alternative Datenbank Dragonfly genutzt.
Durch diese Datenbanken können spezialisierte Architekturen für einen CPU-Kern (Redis) oder Architekturen, die über mehrere CPU-Kerne skalieren (Dragonfly) mit den selben Tests verglichen werden.
In einem Vergleich habe ich diesen Datenbanken meine selbst entwickelte Datenbank (Smade) mit der Shared Everything Architektur gegenüber gestellt.

In mehreren Testreihen (über 10 Tausend Datenpunkte) habe ich festgestellt, dass die Shared Everything Architektur durchaus konkurrenzfähig mit der Shared Nothing Architektur ist.
Besonders in transaktionalen Workloads scheint die Shared Everything Architektur deutliche Performance-Vorteile zu haben.
Vor dem Hintergrund der steigenden Leistungsanforderungen der digitalisierten Welt erscheint es sinnvoll, nicht nur auf die Leistungssteigerung der Prozessoren zu setzen, sondern gleichzeitig auch die dafür notwendige Architektur der Datenbanken weiterzuentwickeln.
Die Shared Everything Architektur kann dafür ein Ansatz sein.
Für eine genauere Betrachtung ist es natürlich wichtig, dass weitere Tests noch ausführlicher und umfangreicher durchgeführt werden, um definitive Antworten zu erhalten.

Zentrale Aspekte der Arbeit sind:
  + Die Implementierung von effizienten Concurrency-Primitiven
  + Ein Algorithmus für die Umsetzung von vielschrittigen Transaktionen
  + Das effiziente Bearbeiten von parallelen Operationen über mehrere Kerne

Diese drei Aspekte werden zusammen in meiner Datenbank Smade angewandt und mit den Datenbanken Redis und Dragonfly mit Blick auf Durchsatzleistung und Latenz verglichen.  

/*
#[

#set par(leading: 0.65em)
#set text(size: 9pt)
#grid(
  columns: (0.4fr, 1fr, 1fr),
  rows: (auto, 2em, auto, 2em),
  [ Durchsatzleistung #linebreak() mehr ist besser ], [ #image("assets/GET-SET P1 G Throughput.png") ],[ #image("assets/MULTI SET 5 R Throughput.png")   ],
  [], [ @abb-throughput-gsp1g], [@abb-throughput-m],
  [ Latenz #linebreak() weniger ist besser], [ #image("assets/GET-SET P1 G Latency.png") ],[ #image("assets/MULTI SET 5 R Latency.png") ],
  [], [ @abb-latency-gsp1g ], [ @abb-latency-m ],

)
]

*/

#pagebreak()
#outline(indent: true)

#pagebreak()

#set page(columns: 2)
#set par(justify: true)
#let algo(x, caption: none) = {
  figure(
    [#align(left)[#algorithm(x)]],
    caption: caption,
    kind: "Algorithmus",
    supplement: "Algorithmus",
    // placement: auto
  )
}

= Zusammenfassung

Viele Datenbanken berufen sich heutzutage auf eine "Shared Nothing" Architektur, um ihre Performanceziele und das Design der Datenbanken zu legitimieren.
In dieser Arbeit wird das gegenteilige "Shared Everything" Design betrachtet, um zu untersuchen, inwiefern dieses vergleichbar ist und welche Vor- und Nachteile es mit sich bringt.
Hierfür wird von mir eine Redis kompatible Alternative im Shared Everything Design implementiert und mit bestehenden Redis kompatiblen Datenbanken verglichen, um die Konkurrenzfähigkeit dieses Designs zu untersuchen.
Im Ergebnniss wird deutlich, dass das Shared Everything Design leistungsfähig ist und in bestimmten Szenarien deutlich effizienter als die Shared Nothing Architektur ist. 

Shared Everything kann also potenziell mit gleichbleibendem Resourcenaufwand mehr Arbeit verrichten oder bei gleichbleibender Arbeit den Resourcenaufwand verringern.

= Motivation und Fragestellung

Die Shared Nothing Architektur ist weit verbreitet und kann schon als Status quo der modernen Datenbankentwicklung gesehen werden.
Interresant in dieser Situation ist allerdings, dass obwohl, oder eventuell gerade weil, viele Datenbanken in diesem Style umgesetzt wurden, es nur wenige Auseinandersetzungen mit dieser Idee gibt.
Besonders bei Datenbanken, die Großteile der Arbeit im Arbeitsspeicher verrichten, ist es fragwürdig, ob eine Shared Nothing Architektur überlegen wäre.

Um eine Diskussionsgrundlage und eine Referenz zu schaffen, ist es notwendig, vergleichbare Werte zu schaffen, anstatt sich auf die Versprechen der Shared Nothing Architektur zu verlassen.
Die Frage, die sich hierbei stellt ist: Inwieweit ist eine Shared Everything Architektur, für diesen Anwendungszweck, im Vergleich zur Shared Nothing Architektur effizienter?

= Hintergrund und theoretische Grundlagen

== Cache-, Lock-, und Resource-Contention

Das grundlegende Problem bei skalierbaren Datenbanken ist das Problem der "Resource Contention."
Hierbei geht es hauptsächlich darum, dass es eine geteilte Ressource gibt, auf die von mehreren CPU-Kernen zugleich zugegriffen werden könnte.
Bei typischen Programmen sind oft Speicher und Locks die wichtigsten Ressourcen, die geteilt werden.
Wird auf ähnliche Speicheradressen von unterschiedlichen CPU-Kernen zugegriffen, so muss der Prozessor diesen Zugriff so koordinieren, dass der Speicher kohärent bleibt, was besonders bei atomaren Operationen aufwendig sein kann.

Im Allgemeinen kann gesagt werden, dass je weniger Contention stattfindet, umso effizienter kann ein einzelner Kern arbeiten.

== Shared Nothing

Shared Nothing basiert auf der Idee, dass es sehr effizient ist, keine Synchronisation von Daten oder von Zugriffen auf Daten zu benötigen. @the-case-for-shared-nothing
In dieser Architektur werden nähmlich keine Daten zwischen mehreren Prozessen geteilt, was dazu führen soll, dass nicht nur der Programmfluss vereinfacht wird, sondern Programme auch effizienter arbeiten können.
So muss die CPU beispielsweise weniger Arbeit in Cache-Coherency oder in atomare Operationen stecken, wenn es keinen geteilten Arbeitsspeicher gibt.
Auch soll so die Skalierbarkeit von Anwendungen erhöht werden, da die angesprochenen Probleme tendenziell mit höheren Zahlen an CPU-Kernen nur größer werden. @cnc-c2clatency

#figure(
render(```
                   +------------+
+------------------+  Datenbank +-------------------+
|                  +------------+                   |
|                                                   |
| +------+  +------+  +------+  +------+  +------+  |
| |Shard1|  |Shard2|  |Shard3|  |  ... |  |ShardN|  |
| +--+---+  +--+---+  +--+---+  +------+  +--+---+  |
|    |         |         |                   |      |
|    V         V         V                   V      |
| +----------------------------------------------+  |
| |                Message Bus                   |  |
| +----------------------------------------------+  |
|    ^         ^         ^                   ^      |
|    |         |         |                   |      |
| +--+---+  +--+---+  +--+---+  +------+  +--+---+  |
| | IO 1 |  | IO 2 |  | IO 3 |  |  ... |  | IO N |  |
| +------+  +------+  +------+  +------+  +------+  |
|                                                   |
+---------------------------------------------------+
```), caption: [Shared Nothing Architektur]
) <abb-sn>

In @abb-sn ist ein typischer Aufbau so einer Datenbank visualisiert.
Hierbei ist es wichtig zu beachten, dass der "Message Bus" nicht eine einzige Datenstruktur sein muss, in der Daten beliebig geteilt werden.
Der Message Bus könnte genau so auch eine kopierte Liste an "Channels" sein, auf die ich in @ch-se noch genauer eingehe.

Grundsätzlich ist es bei einer Shared Nothing Architektur so, dass es bestimmte I/O Threads gibt, die Verbindungen von Datenbankclients verwalten und deren Anfragen annehmen.
Im Gegensatz zu den I/O Threads gibt es Datenbankshards, die jeweils einen Teil der Datenbank verwalten.
Die I/O Threads leiten Anfragen über den Message Bus an die Datenbankshards weiter und diese Shards beantworteten diese Anfrage dann.
Es ist auch möglich, dass ein Thread sowohl als I/O Thread als auch Datenbankshard agiert.
Entscheident ist, dass die Daten zwischen den Shards nicht geteilt werden.

== Shared Everything <ch-se>

Gegenüber diesem Shared Nothing Design steht das Shared Everything Design.
Das zu lösende Problem bleibt gleich, allerdings ist die Lösungsidee umgekehrt.
Nimmt man an, dass kein Speicher zwischen CPU-Kernen geteilt werden soll, so muss es eine direkte Kommunikation zwischen den Kernen geben.
Diese Kommunikation kann über den Concurrency-Primitiven "Channel" gehen.
Das ist ein effizienter Weg #footnote[oft Multi-Producer-Single-Consumer oder Single-Producer-Single-Consumer], um Nachrichten zwischen zwei Kernen auszutauschen, die sonst keine weiteren Daten teilen.

Die Channel haben allerdings einen Overhead in der Kommunikation.
Muss ein CPU-Kern insgesamt 3 Datensätze aus der Datenbank lesen, muss dieser eventuell mit 3 verschiedenen CPU-Kernen kommunizieren, was 6 Nachrichten (3x hin und 3x zurück) bedeutet.
Die Speicher der Channels sind geteilt und können daher einen Synchronisations-Overhead bedeuten.
Das Shared Everything Design zielt darauf ab, diese Kommunikation zu reduzieren und mit günstigen Synchronisations-Primitiven direkt in der Speicherstruktur die Korrektheit von Transaktionen zu garantieren.
Hierbei wird eine bedingte Cache- und Lockcontention beim Zugriff auf die Speicherstruktur gegen den definitiven Kommunikations-Overhead vom Shared Nothing Design abgewogen.

#figure(
render(```
                   +------------+
+------------------+  Datenbank +-------------------+
|                  +------------+                   |
| +----------------------------------------------+  |
| |                Speicherstruktur              |  |
| +----------------------------------------------+  |
|    ^         ^         ^                   ^      |
|    |         |         |                   |      |
| +--+---+  +--+---+  +--+---+  +------+  +--+---+  |
| | IO 1 |  | IO 2 |  | IO 3 |  |  ... |  | IO N |  |
| +------+  +------+  +------+  +------+  +------+  |
|                                                   |
+---------------------------------------------------+
```), caption: [Shared Everything Architektur]
) <abb-se>

In @abb-se ist dargestellt, wie die Shared Everything Architektur definiert ist.
Hierbei gibt es analog zu der Shared Nothing Architektur I/O Threads, die die Datenbankverbindungen und Anfragen verwalten.
Allerdings ist die Datenbank selber, im Kontrast zu der Shared Nothing Architektur nicht aufgeteilt, sondern eine einheitliche Datenstruktur, auf die alle I/O Threads Zugriff haben.
Die I/O Threads selber führen die Anfragen auf der Datenbank aus und kommunizieren über die geteilte Speicherstruktur ihre Zugriffe so, dass die Datenbank kohärent bleibt.

== Vielschrittige Transaktionen

Vielschrittige Transaktionen sind Datenbankanfragen, die aus mehreren einzelnen Operationen bestehen, die alle zusammen atomar ausgeführt werden müssen.

/*
Auch wenn Redis selber keine Rollbacks unterstützt @redis-transactions, die Transaktion in Redis also teilweise ausgeführt werden kann, erachte ich es für sinnvoller, Rollbacks zu unterstützen.
*/

Vielschrittige Transaktion sind daher interessant, da sie erheblich mehr Koordination erfordern, als einzelne Anfragen.
Ich vermute, dass diese Koordination bei einem hohen Kommunikations-Overhead die Effizienz der Datenbank erheblich senkt.

Wird eine Reihe regulärer Anfragen geschickt, so muss in einer Shared Nothing Architektur nur einmal mit dem jeweils betroffenen Shard kommuniziert werden, um diese zu beantworten.
Da Transaktionen aber atomar ausgeführt werden müssen, muss hierbei bereits beim Aufsetzen der Transaktion mit allen Shards kommuniziert werden, um entsprechende Werte in der Datenbank zu sperren.
Danach muss wieder mit allen betroffenen Shards kommuniziert werden, um die einzelnen Befehle auszuführen.

Ich erhoffe mir, dass in einer Shared Everything Architektur der Kommunikations-Overhead deutlich gesenkt werden kann und dadurch die Effizienz gesteigert wird.

= Vorgehensweise, Materialien und Methoden

Um die Fragen zu beantworten, habe ich eine Datenbank implementiert, die in ihrer Funktionalität vergleichbar ist, mit den existierenden Datenbanken Redis @redis und der Alternativimplementation Dragonfly @df.
Redis dient hierbei als Vergleich für eine Architektur mit nur einem Kern und Dragonfly für eine Shared Nothing Architektur, die mit mehreren Kernen skalieren kann.

Bei diesen Datenbanken handelt es sich um Key-Value-Datenbanken @redis-kv, die sich aufgrund ihrer Einheitlichkeit gut für einen Vergleich eignen.
Eine Key-Value-Datenbank kann vereinfacht als eine Hashmap über das Netzwerk beschrieben werden.
Daher werde ich Begriffe, die mit Hashmaps assoziiert sind, in Bezug auf die Datenbanken nutzen. 

Bei den beiden gewählten Datenbanken handelt es sich um In-Memory-Datenbanken.
Auch wenn es viele Beispiele gibt, wo Shared Nothing für persistente Datenbanken, wie Scylla @scylla-sn, genutzt wird, lege ich den Fokus auf In-Memory-Datenbanken, da diese Datenbanken all ihre Arbeit im Arbeitsspeicher verrichten.

== Programmiersprache

Für die Implementierung der Datenbank habe ich verschiedene Programmiersprachen in Betracht gezogen.
Da die Datenbank vergleichbar sein muss mit Redis und Dragonfly, muss sie in einer vergleichbaren Sprache umgesetzt werden, die keine zusätzliche Hürden wie einen Garbage Collector oder JIT Compiler einführen.

Die Sprachen, die sinnvoll schienen, waren C, C++, Rust @rust, und Zig @ziglang.
Ich habe mich für Zig entschieden, da die Sprache recht simple ist im Vergleich zu C++, generische Typen erlaubt im Gegensatz zu C, und nicht so viele Probleme bereitet wie Rust, wenn es darum geht, Daten (scheinbar) willkürlich zwischen mehreren Threads zu teilen.

== Speicherstruktur (Dash) <ch-dash>

Um einen parallelen Zugriff auf die Speicherstruktur zu ermöglichen, habe ich mich an dem Design von Dash @dash orientiert.
Auch Dragonfly orientiert sich an diesem Design, doch nutzt Dragonfly Dash nicht, um parallelen Zugriff zu ermöglichen, sondern um einen effizienten Speicher auf _einem_ Kern bereitzustellen @df-dash.
Dash ist eine Datenstruktur, die auf Extendible-Hashing basiert und für parallelen Zugriff optimiert ist, insbesondere darauf, dass möglichst wenig Speicher geschrieben werden muss.
Da Dash allerdings eine recht ausführliche Datenstruktur ist, habe ich es mir erlaubt, diese an mehreren Stellen zu vereinfachen.

=== Buckets

Dash beschreibt, wie Buckets Implementiert werden können.
Um diese einfach und effizient zu gestallten, habe ich meine Buckets anders implementiert.
Ein Bucket hat dabei maximal 16 Einträge.
Für jeden Eintrag gibt es 16bit an Zusatzdaten und einen 32bit Expiry-Zeitpunkt.
Die Zusatzdaten, Expiry-Zeitpunkte und Einträge sind dabei alle jeweils in einem kontinuirlichen Array abgebildet.
Das ist daher wichtig, da so die Zusatzdaten und Expiry-Einträge mit Vektoroperationen durchsucht werden können. 
In @layout-bucket ist dieses Layout einmal aufgezeigt.

#figure(
  table(columns: (1fr,), stroke: none, row-gutter: 9pt,
    math.overbrace(table(columns: (1fr, 1fr, 0.7fr, 1fr),[Meta1],[Meta2],$dots$,[Meta16]), "16x2bytes"),
    math.overbrace(table(columns: (1fr, 1fr, 0.7fr, 1fr),[Expiry1],[Expiry2],$dots$,[Expiry16]), "16x4bytes"),
    math.overbrace(table(columns: (1fr, 1fr, 0.7fr, 1fr),[Entry1],[Entry2],$dots$,[Entry16]), "16x48bytes"),
  ), caption: "Memory Layout eines Buckets", supplement: "Layout") <layout-bucket>

Alle Daten eines Eintrages, zum Beispiel Eintrag1/Entry1, ergeben sich aus dem Betrachten der dazugehörigen Expiry und Zusatzdaten, also Meta1 und Expiry1. 
Die Zusatzdaten bestehen aus einem 15bit Fingerabdruck des Eintrages und einem Bit, der angibt, ob der Eintrag hier existiert.
Der Fingerabdruck besteht dabei einfach aus den letzten 15bit des Hashes des Keys des Eintrages.

In @algo-bucket-find wird beschrieben, wie ich Vektoroperationen nutze, um effizient die Indizes der Einträge zu finden, wenn ein Hash von einem gesuchten Eintrag gegeben ist.
Es werden für die Zusatzdaten in einem Vektor mit den Dimensionen $16 "Einträge" times 2 "Byte"$ genutzt.
Dabei werden die existierenden Zusatzdaten mit dem Fingerabdruck des Eintrags verglichen nachdem gesucht wird.
Alle Indizes des Vektors, bei dem die Fingerabdrücke des Eintrags der Suche gleich dem des Eintrags in dem Bucket sind, werden mit einem Integer der Form $1 << n$ gefüllt.
Hierbei ist $n = 15-"Index"$.
Wird dieser Vektor dann mit einer "Or"-Operation zu einem 16bit Integer reduziert, befinden sich mögliche Einträge immer in den Indizes, bei denen der 16bit Integer eine 1 hat.
In Kombination mit der "Count-Leading-Zeros" Operation von modernen CPUs kann dies sehr effizient umgesetzt werden.

#algo({
  import algorithmic: *
  Assign([msb_idx], [Vec16x2{1 << 15, ..., 1 << 0}])
  State[]
  Function("Bucket-FindEntry", args: ("bucket", "hash"), {
    Assign([vec_a], FnI([VecLoad16x2], [bucket.meta]))
    Assign([fingerprint], [(hash&0x7fff << 1) | 1])
    Assign([vec_b], FnI([VecFill16x2], [fingerprint]))
    Assign([eq_mask], FnI([VecEq], [vec_a, vec_b]))
    Assign([selected], FnI([VecSelect], [eq_mask, msb_idx]))
    Assign([msb_int], FnI[VecReduceOr][selected])
    Return[msb_int]
  })
}, caption: [Bucket-FindEntry]) <algo-bucket-find>

Auf ähnliche Art und Weise können auch freie Indizes gesucht werden und Indizes gefunden werden, die abgelaufen sind.

/**/
Da die Expiry-Daten allerdings 4byte groß sind und das Verarbeiten von allen auf einmal eine 512bit Vektor-Unterstützung bräuchte, habe ich mich dazu entschieden, die Expiry Daten in 2 Schritten mit jeweils 8 Einträgen abzuarbeiten, da 256bit Vektoreinheiten deutlich weiter verbreitet sind als 512bit Vektoreinheiten in x64 CPUs.
/**/

=== SmallMap

18 Buckets werden in eine "SmallMap" zusammengefasst.
18 kommt daher, da die SmallMaps damit sehr gut in die Allocator-Page meines Allocators (siehe @ch-alloc) passen. 
Die SmallMaps werden dann als Baustein genutzt um Dash aufzubauen und damit Extendible-Hashing zu betreiben.

Eine SmallMap dient als kleinste Einheit von Transaktionen in der Datenbank und ist daher mit einem Lock versehen (siehe @ch-queue für die Details des Locks).
Auf die SmallMap können Leseoperationen mit Optimistic-Concurrency durchgeführt werden und nur für Schreiboperationen muss das Lock tatsächlich gesperrt werden.

Ist eine SmallMap voll und es wird versucht weitere Einträge hinzuzufügen wird erst geprüft, ob abgelaufene Einträge, erkennbar an den Expiry-Daten, entfernt werden können.
Ist das nicht der Fall, wird eine neue SmallMap reserviert und etwa die Hälfte aller Einträge in die neue SmallMap übertragen.
Die neue SmallMap wird dann zu der Datenbank hinzugefügt.

=== Vergrößern der Speicherstruktur <ch-extend>

Auch beim Vergrößern der Speicherstruktur weiche ich von Dash ab.
Im Gegensatz zu Dash wird beim Starten der Datenbank ein Limit an SmallMaps festgelegt.
Damit wird das Directory, das alle SmallMaps im Style von Extendible-Hashing speichert, direkt am Anfang mit der maximalen Größe reserviert.
Das verhindert nicht nur Latenzspitzen, die aufgrund von unerwarteten Speicherreservirungen auftreten, sondern das Vergrößern ist so auch deutlich einfacher.
In @abb-dict-extension1 ist beispielhaft einmal eine Speicherstruktur dargestellt, die auf 2 SmallMaps zeigt.

#figure(
render(```
             1   2   3   4   5   6
           +---+---+---+---+---+---+---+
Directory: | * | * | O | O | O | O |...|
           +-|-+-|-+---+---+---+---+---+
             |   |
             v   v
            .+. .+.
SmallMaps:  |_| |_|
            | | | |
            '-' '-'
             1   2
```), caption: [Directory vor der Vergrößerung]
) <abb-dict-extension1>

Wenn die SmallMap 2 zu klein ist, um Daten zu Speichern, wird das Directory erst erweitert wie in @abb-dict-extension2.
Hierbei werden die Pointer des Directories auf die bereits existierenden SmallMaps gesetzt.

#figure(
render(```
             1   2   3   4   5   6
           +---+---+---+---+---+---+---+
Directory: | * | * | * | * | O | O |...|
           +-|-+-|-+-|-+-|-+---+---+---+
             |.~~+~~~'   :
             |   |.~~~~~~'
             |   |
             v   v
            .+. .+.
SmallMaps:  |_| |_|
            | | | |
            '-' '-'
             1   2
```), caption: [Directory nach der Vergrößerung]
) <abb-dict-extension2>

Danach wird etwa die Hälfte der Einträge aus SmallMap 2 in eine neue SmallMap verschoben.
In @abb-dict-extension3 wird veranschaulicht, wie die neue SmallMap hinzugefügt wird und somit die Kapazität erhöht wird.

#figure(
render(```
             1   2   3   4   5   6
           +---+---+---+---+---+---+---+
Directory: | * | * | * | * | O | O |...|
           +-|-+-|-+-|-+-|-+---+---+---+
             |.~~+~~~'   |
             |   |       |
             v   v       v
            .+. .+.     .+.
SmallMaps:  |_| |_|     |_|
            | | | |     | |
            '-' '-'     '-'
             1   2       3
```), caption: [Directory hinzufügen einer weiteren SmallMap]
) <abb-dict-extension3>

Da ich im Unterschied zu Dash bereits die gesamte Größe des Directories reserviert habe, können alle Operationen bis auf die, die eine SmallMap aufteilen, normal fortfahren, während das Directory erweitert wird.
So werden die meisten Lese- und Schreiboperationen nicht blockiert.

Damit verhindert wird, dass zwei Threads zur gleichen Zeit versuchen die Datenbank zu vergrößern, wird eine Flag mit Atomaren-Operationen gesetzt.
Die Flag gibt an, dass die Datenbank aktuell vergrößert wird.

/**/

#if bll [

== Darstellung von Datenbank-Werten

Alle Werte, die in der Datenbank gespeichert werden haben das Format, welches in @layout-dbvalue dargestellt wird und insgesammt 24byte groß ist.

#figure(
  [#table(columns: (auto,1fr,), stroke: none, row-gutter: 5pt, align: left,
    [String], [#math.overbrace([`CCCCCCCC`], "Capacity")#math.overbrace([`LLLLLLLL`], "Length")#math.overbrace([`PPPPPPPP`], "Pointer")],
    [Short-String], [#math.overbrace([`DDDDDDDDDDDDDDDDDDDDDD`], "Data")`LF`],
    [Liste], [#math.overbrace([`PPPPPPPP`], "Pointer")#math.overbrace([`LLLLLLLL`], "Length")#math.overbrace([`UUUUUUU`], "Unused")`F`],
    [Andere], [#math.overbrace([`PPPPPPPP`], "Pointer")#math.overbrace([`UUUUUUUUUUUUUU`], "Unused")`FF`],
  )
  `F` entspricht "Flag" und speichert, den Datentyp.
  ], caption: "Datenbank-Werte", supplement: "Layout"
) <layout-dbvalue>

Hierbei handelt es sich um einen Union-Type, der 3x8byte groß ist, wobei die letzten beiden Bits genutzt werden, um die Typen der Union zu unterscheiden.
Das geht, weil alle Daten von Strings in der Datenbank 8byte alligned sind und daher die letzten beiden Bits eines gültigen Pointers immer 0 sind.
Sind die letzten beiden Bits 0, so handelt es sich also um einen String.
Ist der letzte Bit 1, so handelt es sich um einen "Short-String", der seine Daten in der Datenstruktur selber speichert anstatt in einer Stelle außerhalb.
Ein Short-String kann bis zu 22bytes lang sein.
Sind die letzten beiden Bits 1, so sind andere Datentypen beschrieben.
Das kann eine (Linked-)Liste sein, die nur 2 der 8byte-Felder braucht, um den Head der Liste sowie ihre Länge zu speichern oder auch viele andere Datentypen.

/**/
]

== Memory-Management <ch-alloc>

Für das Memory Management habe ich als Grundlage eine vereinfachte Version von Microsofts mimalloc @mimalloc implementiert.
Das ist nicht nur aus dem Grund notwendig, da Zig noch keinen starken und allgemeinen Allocator bereitstellt, sondern auch daher, dass ich aufgrund der Shared Everything Architektur besondere Anforderungen an mein Memory-Management habe.

In der Shared Everything Architektur stellt sich nämlich im Gegensatz zur Shared Nothing Architektur die Frage, wann es sicher ist, Speicher wieder an das Betriebssystem zurückzugeben.
Das Problem ist nämlich, dass ich aufgrund von der Verwendung von Optimistic-Concurrency gleichzeitig einen schreibenden und mehrere lesende Threads auf der gleichen Speicheradresse haben kann.
Würde der schreibende Thread die Speicheradresse wieder zurück an das Betriebssystem geben, während ein lesender Thread noch die Daten liest, würde es zu Fehlern kommen.
Um dieses Problem zu lösen, habe ich mich dazu entschieden, dass kein Speicher jemals an das Betriebssystem zurückgegeben wird, sondern beim Start der Datenbank eine feste Menge an Speicher angegeben wird und von der Datenbank verwendet wird.

Wenn ein schreibender Thread entscheidet Speicher freizugeben, wird dieser nur an den Allocator gegeben, der den Speicher nicht an das Betriebssystem zurückgibt.
Der Allocator gibt den Speicher an einen Thread zurück, wenn dieser mehr Speicher benötigt.

== Concurrency und I/O

Meine Umsetzung der Datenbank orientiert sich an modernen Concurrency und I/O Modellen und nutzt für Concurrency State-Machines und für I/O die asynchrone API io_uring @io-uring.
Da ich meine Datenbank in der Programmiersprache Zig implemtiere und diese zu diesem Zeitpunkt noch keine fertige Untertützung für async/await hatte, habe ich mich dazu entschieden, Concurrency mit der Hilfe von State-Machines zu implementieren.
Diese State-Machines werden in einem Event-Loop pro Thread immer wieder aufgerufen und können so schrittweise Fortschritt erreichen ohne den Thread durchgängig zu blockieren.
So kann eine State-Machine, die beim Versuch ein Lock zu sperren scheitert, speichern, dass sie es an diesem Punkt erneut später versuchen muss.
Nach dem Speichern kann die State-Machine die Kontrolle zurück an den Event-Loop geben, der die State-Machine zu einem späteren Zeitpunkt wieder aufruft.

== Queue Lock <ch-queue>

Um die Latenz der Datenbank vorhersehbar zu gestalten, ist es wichtig, dass keine Operation theoretisch unendlich lang dauern kann.
Da Locks aber teilweise notwendig sind, um eine effiziente Arbeitsweise zu ermöglichen, habe ich das Queue-Lock entwickelt, was dazu dient,
dass alle Schreiboperationen in derselben Reihenfolge passieren, in der sie das erste Mal probiert werden.
Das soll verhindern, dass, wenn eine Operation immer wieder versucht, das Lock für Schreiboperationen zu sperren, diese nicht von immer neuen Operationen geblockt werden kann.
So könnte es sein, dass es einen Thread gibt, der es immer wieder schafft das Lock für sich zu sperren und damit immer einen anderen Thread aussperrt.

Daher habe ich einen Locking-Mechanismus entworfen, der dieses Problem umgehen soll: das "Queue-Lock".
Bei dem Queue-Lock gibt es die garantierte Reihenfolge, was in @algo-queue-lock und @algo-queue-trylock beschrieben wird.
Hierbei wird ein 64bit Integer als Lock genutzt.
Dieser 64bit Integer wird allerdings als zwei 32bit Integer ($l 32 eq.est $ low 32bits und $h 32 eq.est $ high 32bits) betrachtet.
Das Queue-Lock kann als Warteschlange betrachtet werden, daher auch der Name.
In den high 32bits wird gespeichert, wie viele Threads noch in der Schlange stehen und in den low 32bits wird gespeichert, der wievielte Thread gerade dran ist.
Wenn sich ein Thread in die Schlange einreiht (die high 32bits werden um 1 erhöht) gibt es zwei Möglichkeiten: Entweder ein anderer Thread ist vor dem eigenen Thread in der Schlange oder nicht.

/**/
Wenn ein anderer Thread gerade vor einem ist, kann man regelmäßig prüfen, wieviele bereits an der Reihe waren (siehe @algo-queue-trylock).
Wenn kein Thread vor einem ist, ist man selber an der Reihe.
So kommt ein Thread garantiert dazu, das Lock zu sperren. 
/**/

#algo({
    import algorithmic: *
    Function("QueueLock-Lock", args: ("lock",), {
      Assign([old], FnI[AtomicIncr][lock.h32])
      Assign([slot], [old.h32])
      Assign([pos], [old.l32])
      If(cond: "slot = 0", (
        FnI("AtomicIncr", "lock.l32"),
        Return([Acquired])
      ))
      If(cond: "slot+(pos>>1) >= ROLLOVER", {
        Assign([slot], [slot - ROLLOVER])
      })
      Return([Queued: slot+(pos>>1)])
    })
}, caption: [QueueLock-Lock]) <algo-queue-lock>

/**/
#algo({
    import algorithmic: *
    Function("QueueLock-LockSlot", args: ("lock", "slot",), {
      Assign([old], FnI[AtomicLoad][lock])
      If(cond: "slot << 1 = old.l32", (
        FnI("AtomicIncr", "lock.l32"),
        Return[Acquired]
      ))
      Return[Pending]
    })
}, caption: [QueueLock-LockSlot]) <algo-queue-trylock>

#if bll [

Nachdem ein Thread an der Reihe war verlässt dieser die Schlange und veringert zum einen die high 32bits, weil nun ein Thread weniger in der Schlange ist und erhöht zum anderen die low 32bits, weil ein Thread mehr nun fertig ist (siehe @algo-queue-unlock).

#algo({
    import algorithmic: *
    Function("QueueLock-Unlock", args: ("lock",), {
      Assign([old], FnI[Atomic IncrL32+DecH32][lock])
      If(cond: "old.l32 > ROLLOVER", {
        FnI[AtomicDecr][lock, ROLLOVER]
      })
    })
}, caption: [QueueLock-Unlock]) <algo-queue-unlock>

]

Optimistic-Concurrency lässt sich mit diesem Lock relativ simpel umsetzen, in dem zu Beginn einer lesenden Operation die unteren 32bit des 64bit Locks als Version gespeichert werden.
Ist die Version ungerade, so ist das Lock in einem schreibendem Modus gesperrt und die lesende Operation muss warten.
Ist die Version gerade, so kann die lesende Operation beginnen.
Wenn die lesende Operation fertig ist, muss sie nur die gespeicherte Version mit den unteren 32bit des Locks vergleichen.
Sind diese unterschiedlich, so muss die lesende Operation neu starten; sind sie gleich, so war die Operation erfolgreich.

== Vielschrittige Transaktionen

Vielschrittige Transaktionen sind Datenbankoperationen, die in einer Transaktion mehrere Operationen so ausführen, dass sie für den Rest der Datenbank als eine einzige Operation wirken.
Wenn eine Transaktion beispielsweise die Schritte beinhaltet "Setze A auf 1 und B auf 2" und A und B vorher 0 waren, so gibt es keinen Zeitpunkt an dem A als 1 und B als 0 oder A als 0 und B als 2 gelesen werden können.
Es kann nur A als 0 und B als 0 oder A als 1 und B als 2 gelesen werden.

Damit solche Transaktionen in einer Datenbank effizient koordiniert werden, wird oft auf Lock-Manager wie VLL @vll, der auch in Dragonfly genutzt wird, zurückgegriffen.
Auf der Suche nach einem angemessenen Lock-Manager ist mir aufgefallen, dass nur wenige für meine gewählte Architektur passend sind und diese oft deutlich mehr Funktionalität mitbringen als ich benötige.
Daher habe ich mich dazu entschieden, ein eigenes Transaktionsschema zu entwickeln, welches möglichst gut auf meine Datenbank passt.

Mein Transaktionsschema funktioniert so:
  + Alle SmallMaps, die für die Transaktion benötigt werden, werden als Pointer aus dem Directory geladen und in ein Array gespeichert.
  + Die SmallMaps werden nach ihrem Pointerwert in aufsteigender Reihenfolge sortiert.
  + Die Locks der SmallMaps werden in der Reihenfolge nun aufsteigend gesperrt. Es kann passieren, dass eine falsche SmallMap gesperrt wird, da zwischen Punkt 1 und dem Sperren der SmallMap der Wert, der für die Transaktion erforderlich ist, sich nun in einer anderen SmallMap befindet (siehe @ch-extend). Dann wird die falsch gesperrte SmallMap einfach wieder entsperrt und die richtige SmallMap gesucht und in das sortierte Array an die richtige Stelle eingefügt. 

Zu Punkt 3 ist anzumerken, dass alle bereits gesperrten Pointer, die einen größeren Wert haben als der neu geladene, wieder entsperrt werden müssen, um Deadlocks zu vermeiden.

Diese Art vielschrittige Transaktionen durchzuführen, ist sicher vor Deadlocks, da die SmallMaps immer in aufsteigender Reihenfolge gesperrt werden.
Intuitiv ist das schlüssig und es lässt sich auch durch einen einfachen Beweis durch Widerspruch zeigen, dass Deadlocks so vermieden werden:
  + Annahme: Es gibt ein Deadlock. Dieser muss entstanden sein, weil ein Thread \#1 auf eine SmallMap wartet, die ein anderer Thread \#2 gesperrt hat und Thread \#2 wartet auf eine SmallMap die Thread \#1 gesperrt hat.
  + Per Definition: Alle SmallMaps, die ein Thread sperrt, werden in einer aufsteigenden Reihenfolge gesperrt.
  + Aus 2 folgt: Thread \#1 wartet auf eine SmallMap $s_1$, die größer ist als alle bereits gesperrten von Thread \#1. Thread \#2 wartet auf eine SmallMap $s_2$, die größer ist als alle bereits gesperrten von Thread \#2.
  + Aus 1 und 3 folgt: Thread \#1 wartet auf $s_1$, die von Thread \#2 gesperrt ist und größer ist als alle bereits gesperrten von Thread \#1, aber Thread \#2 wartet auf $s_2$, die von Thread \#1 gesperrt ist.
  + Aus 4 folgt: Da Thread \#2 $s_1$ gesperrt hat und $s_2$ sperren will, muss $s_1 < s_2$ sein. Da Thread \#1 $s_2$ gesperrt hat und $s_1$ sperren will, muss also auch $s_2 < s_1$ sein.
  + Daraus folgt: $s_1 < s_2 < s_1$ was ein Widerspruch ist und daher nicht auftreten kann.

== Performance messen und vergleichen <ch-messen>

Das Messen der Performance hat sich schwieriger als erwartet herausgestellt.
Nicht nur ist es der Fall, dass es keinen verbreiteten Test für vielschrittige Transaktionen gibt, sondern auch, dass das oft genutzte Tool "Memtier", das von Redis zum Testen von Datenbanken eingeführt wurde @memtier,  sich als weniger skalierbar als meine Implementation der Datenbank herausstellt und daher keine festen Ergebnisse liefern konnte.

#figure(image("./assets/round3 memtier.png"), caption: [Anfragen pro Sekunde vs CPU-Kerne: Ein Test mit Memtier mit problematischen Werten]) <abb-memtier-values>

In @abb-memtier-values ist zu erkennen, wie die Werte (siehe auch @ch-ergebnisse) von "smade Ops/Sec" mit 10 Kernen einbrechen, danach aber wieder größer werden, was im Kontext keinen Sinn ergibt.
Auch, dass Dragonfly nicht über 12 Kerne skaliert, ist fragwürdig.
Zusammen mit vielen weiteren Tests habe ich herausgefunden, dass Memtier, selbst wenn es die gleiche Menge an Ressourcen zur Verfügung hat, deutlich mehr Leistung benötigt als die Datenbanken.
Daher ist es schwierig, damit und mit meinen begrenzten Computer-Ressourcen gute Daten zu erheben.
Um dieses Problem zu umgehen, habe ich zusätzlich ein Tool namens "Loader" entwickelt und implementiert, das die Aufgabe des Messens übernehmen soll.

Aber was wird überhaupt gemessen?
Drei Metriken sind besonders wichtig beim Betrachten von Architekturunterschieden zwischen Datenbanken:
  - Latenz
  - Durchsatzleistung
  - Skalierbarkeit

Hierbei ist zu beachten, dass zwar im Allgemeinen oft $"Latenz" prop 1 / "Durchsatzleistung"$ gilt, das aber nicht der Fall sein muss und die Latenz ja auch für diverse Perzentile betrachtet werden sollte.
Für den Vergleich habe ich also folgende Metriken und Einheiten ausgewählt:
  
  - Latenz in $mu s$ für Durchschnitt, p50, p80, p90, p99, p99.9, p99.995, und p99.999
  - Durchsatzleistung in Anfragen pro Sekunde (QPS)
  - Skalierbarkeit in $%$. Sie ergibt sich aus der folgenden Rechnung: $"Skalierbarkeit" = "QPS mit N Kernen"/"QPS mit 1 Kern"$

Gemessen wurden diese Metriken durch mein Tool, Loader, wie folgt:

Als Erstes wird ein Threadpool gestartet und jeder Thread verbindet sich mit einer festen Anzahl an Verbindungen mit der jeweiligen Datenbank.
Sobald eine Verbindung aufgebaut ist, beginnt diese Anfragen an die Datenbank zu schicken, mit einem festgelegten Format.
Sobald jede Verbindung Anfragen schickt, wird mit der Messung begonnen.
Gemessen wird dann 20 Sekunden lang unter Volllast.
Für jede Anfrage wird die Latenz gemessen und gespeichert.
Die Durchsatzleistung ergibt sich nach den 20 Sekunden aus den gesamt gemessenen Anfragen geteilt durch 20 Sekunden.
Die Latenz-Metriken (Durchschnitt, p50 etc. etc.) ergeben sich aus der Akkumulation der gespeicherten Latenzen.

Dieser Test wird für die Datenbanken mit unterschiedlicher Anzahl an Kernen durchgeführt, woraus die Skalierbarkeit abgeleitet werden kann.

Außerdem müssen mehrere Workloads getestet werden, um verschiedene Szenarien zu simulieren.
Ich habe mich für 8 verschiedene Workloads entschieden, die ein breites Spektrum an Fällen simulieren sollen:
  + 8 Pipelined Inserts (pipelined bedeutet, dass alle Anfragen gleichzeitig geschickt werden, ohne auf einzelne Antworten zu warten). Das ist ein writeonly Szenario, das auftreten kann, wenn eine Datenbank von einer anderen Quelle befüllt wird.
  + 90% Read, 10% Write. Das ist ein Workload, der sehr typisch ist, da oftmals deutlich mehr Daten abgerufen werden, als geschrieben werden. Dieser Workload wird sowohl mit einer gleichförmigen Schlüsselverteilung als auch mit normalverteilter Schlüsselverteilung getestet (um Hotspots zu simulieren) und in beiden Fällen mit einer Pipeline von 1 und 8 getestet.
  + 10% Read, 90% Write. Dieser Workload ist eher untypisch, aber relevant, um zu erkennen, ob Leseoperationen möglicherweise von Schreiboperationen verdrängt werden. Dieser Workload wird auch sowohl mit einer gleichförmigen Schlüsselverteilung als auch mit normalverteilter Schlüsselverteilung getestet.
  + 5 Writes in einer Transaktion. Dieser Workload überprüft die Performance bei vielen langlaufenden Transaktionen.

= Ergebnisse <ch-ergebnisse>

Die Tests wurden auf AWS Ubuntu Intel x64 Instanzen mit 32 Kernen und 64 virtuellen Kernen durchgeführt (siehe auch  @ch-messen).
Für eine hohe Vergleichbarkeit wurden alle Tests und alle Datenbanken auf derselben AWS-Instanz getestet, um Probleme wie Temperaturschwankungen, golden Samples oder Noisy-Neighbours zu vermeiden.
Zudem wurde jeder Test einmal durchgeführt, wenn die Datenbank festgelegte Threads hatte und einmal ohne.
Das heißt "Affinity" und ist in den Ergebnissen mit "aff" gekenzeichnet.

== Lese-dominierte Workloads

Werfen wir zuerst einen Blick auf die Workloads, die keine Pipeline nutzen.

Alle Graphen für die Durschsatzleistung werden wie @abb-throughput-gsp1g dargestellt.
In den Graphen ist meine Datenbank als "Smade" bezeichnet.
Für die Durchsatzleistung sind auf der x-Achse die getesteten Kerne dargestellt und auf der y-Achse die gemessene Performance in Ops/Sec. 
In @abb-throughput-gsp1g ist zu erkennen, dass die Affinity wenig Einfluss auf die Durchsatzleistung der Datenbanken hat.
Außerdem ist die Performance bei nur einem einzelnen Kern unabhängig vom Design nahezu identisch.

#figure(image("./assets/GET-SET P1 G Throughput.png"), caption: [Durchsatzleistung Ops/Sec vs Kerne: 90% Read, 10% Write, pipeline=1, normalverteilte Schlüssel]) <abb-throughput-gsp1g>

In @abb-latency-gsp1g ist die Latenz der Datenbanken mit 16 Kernen (bzw. 1 Kern im Fall von Redis, da Redis keine Konfiguration für mehrere Kerne erlaubt) visualisiert.
Wichtig ist hierbei die logarithmische Skalierung der y-Achse zu beachten.

#figure(image("./assets/GET-SET P1 G Latency.png"), caption: [Latenz $mu$s vs Perzentil: 90% Read, 10% Write, pipeline=1, normalverteilte Schlüssel]) <abb-latency-gsp1g>

Zu erkennen ist, dass die Performance von Dragonfly und Smade recht nahe beieinander liegt, die Versionen mit Affinity aber entgegen der Intuition eine etwas höhere Latenz haben.

== Schreib-dominierte Workloads

Gleiche Ergebnisse, mit relativ ähnlichen Werten, gibt es auch für die schreib-dominierten Workloads.
Entgegen der Intuition bleibt die Durchsatzleistung (@abb-throughput-sgp1g) und Latenz (@abb-latency-sgp1g) nahezu unverändert im Vergleich mit den lese-dominierte Workloads.

#figure(image("./assets/SET-GET P1 G Throughput.png"), caption: [Durchsatzleistung Ops/Sec vs Kerne: 10% Read, 90% Write, pipeline=1, normalverteilte Schlüssel]) <abb-throughput-sgp1g>
#figure(image("./assets/SET-GET P1 G Latency.png"), caption: [Latenz $mu$s vs Perzentil: 10% Read, 90% Write, pipeline=1, normalverteilte Schlüssel]) <abb-latency-sgp1g>

== Pipelined Workloads

Auf den ersten Blick mag es so scheinen, als wäre "Smade" mit der Shared Everything Architektur am schnellsten.
Es stellt sich jedoch die Frage, ob das tatsächlich an der Architektur liegt oder villeicht an anderen Faktoren, wie die Implementation des I/Os.
Um diese Frage zu beantworten, lohnt es sich, die pipelined und transaktionalen Workloads anzuschauen.
Hierbei werden gleichbleibende Lasten, wie z.B. I/O, weniger repräsentiert als in den Workloads mit nur einer einzigen Anfrage.
Wenn der Abstand zwischen Dragonfly und Smade schrumpft, ist das ein guter Indikator dafür, dass dieser Performanceunterschied nur an architekturunabhänigen Faktoren wie I/O liegt.

Wie in @abb-throughput-sgp8g zu erkennen ist, ist die Performance von Redis und Smade bei einem Kern wieder nahezu identisch.
Im Kontrast dazu ist die Performance von Dragonfly mit einem Kern geringer als die von Redis und erst mit 2 Kernen holt Dragonfly dieses Defizit auf.
Die Performancedifferenz zwischen Dragonfly und Smade wächst über die Kerne immer weiter.
Während es bei einem Kern nur etwa 40% sind, so beträgt diese bei 8 und mehr Kernen mehr als 100%.
Es scheint also so, als würde Dragonfly hier deutlich weniger skalieren, als im Test mit nur einer Anfrage zurzeit.

#figure(image("./assets/SET Throughput.png"), caption: [Durchsatzleistung Ops/Sec vs Kerne: 100% Write, pipeline=8, zufällige Schlüssel]) <abb-throughput-sgp8g>

In @abb-latency-sgp8g sind die Latenzen dieses Tests dargestellt und es ist  zu erkennen, dass Dragonfly im Durchschnitt eine bedeutend langsamere Latenz als Smade hat. 

#figure(image("./assets/SET Latency.png"), caption: [Latenz $mu$s vs Perzentil: 100% Write, pipeline=8, zufällige Schlüssel]) <abb-latency-sgp8g>

Interessant ist hierbei allerdings die Latenzspitze von Smade im p99.999, die nicht bei 14 oder weniger Kernen existiert oder bei Tests ohne Affinity.
Während ich diese noch nicht eindeutig klären konnte, scheint es so, als läge es an der Art und Weise, wie ganz genau die Anfragen bearbeitet werden, zusammen mit Unregelmäßigkeiten im System.

Ein ähnliches, aber noch extremeres Ergebnis ergibt sich bei den Transaktionen.
Ich habe ja die Hypothese aufgestellt, dass Transaktionen besonders viel Overhead mit der Kommunikation in einer Shared Nothing Architektur haben und die Werte aus @abb-throughput-m sind ein Indiz dafür.

#figure(image("./assets/MULTI SET 5 R Throughput.png"), caption: [Durchsatzleistung Ops/Sec vs Kerne: Transaktion mit 5x Write, zufällige Schlüssel]) <abb-throughput-m>

In @abb-throughput-m ist zu erkennen, wie die Durchsatzleistung von Dragonfly nun deutlich hinter der von Redis bei einem Kern liegt, während Smade bei einem Kern ein kleines bisschen vor Redis liegt.
Dieser Datensatz ist in Kombination mit dem aus @abb-throughput-sgp8g extrem bedeutsam, denn vom äußeren Aufbau sind die Anfragen sehr ähnlich.
Die Transaktion ist pipelined, so auch die 8 pipelined Write-Anfragen.
Auch vom I/O sind sie sehr ähnlich.
Die Transaktion besteht zwar nur aus 5 Write-Anfragen, allerdings haben Transaktionen etwas mehr I/O-Aufwand.
Also existiert in beiden Workloads etwa die gleiche Arbeit, mit dem einzigen Unterschied, dass die Transaktion atomar passieren muss.
Dieser Unterschied erhöht die Performancedifferenz von den 100% auf mehr als 450% zwischen den beiden Datenbanken.
Auch in der Latenz in @abb-latency-m wird ein Performanceeinbruch von Dragonfly sichtbar.

#figure(image("./assets/MULTI SET 5 R Latency.png"), caption: [Latenz $mu$s vs Perzentil: Transaktion mit 5x Write, zufällige Schlüssel]) <abb-latency-m>

Die Latenz von Smade bleibt vergleichbar mit den nicht atomaren Anfragen und die Latenz von Redis sinkt, aber die Latenz von Dragonfly übertrifft die von Redis bei den hohen Perzentilen und ist auch im Durchschnitt höher als im anderen Test. 

= Ergebnissdiskussion

Nach dem Betrachten der Ergebnisse scheint es so, als wäre eine Shared Everything Architektur in bestimmten Anwendungsfällen den gängigen Alternativen überlegen.
Der Fokus dieser Arbeit liegt auf der Einordnung der Shared Everything Architektur, und die Frage ist, wie effizient diese sein kann.

== Anwendbarkeit

Die Ergebnisse zeigen, dass eine Shared Everything Architektur einer Shared Nothing Architektur gegenüber viele Vorteile haben kann, doch es haben sich bei meiner Arbeit auch einige Probleme mit dieser Architektur gezeigt.
Eines der großen Probleme ist, dass es für viele Datenstrukturen keine einfache Shared Everything Alternative gibt.
Das gilt auch für viele Index-Strukturen.
Diese Ergebnisse sind also nur in einem sehr begrenzten Rahmen zu betrachten und sollten nicht weit über die in dieser Arbeit vorgestellte Datenbank ohne weitere Nachforschungen extrapoliert werden.

== Qualität der Ergebnisse

Auch wenn ich mir meiner Messmethodik recht sicher bin, ist der Umfang der erhobenen Daten kaum ausreichend, um die vielen Faceten der Performance zu erfassen.
Während beispielsweise die Ergebnisse, wie ich sie hier gezeigt habe, in mehreren Durchläufen relativ wiederholbar waren, wurden alle nur in einem sehr spezifischen Szenario erhoben.
So stellt sich die Frage, ob die Ergebnisse zur gleichen Aussage kämen, wenn die Datenbank auf AMD Hardware oder ARM IP getestet werden würde oder wie sich die Datenbank verhält, wenn die Anzahl an Datenbankclients verändert wird. 

Auch gibt es in der Datenbank noch einige Probleme, die noch nicht vollständig behoben oder durchdrungen wurden, wie die angesprochene Latenzspitze oder einige Probleme der Speicherverwaltung unter anderem, dass in bestimmten Szenarien scheinbar Speicher nicht recycelt wird.
Hierbei stellt sich die Frage, ob und zu welchen Maß diese Probleme die Performance der Architektur beinflussen.

Um noch sicherere Ergebnisse zu erhalten, bedarf es noch mehr Messungen, auch wenn für diese Arbeit mehr als 10 Tausend Datenpunkte erhoben und analysiert wurden.
Die Datenbank sollte außerdem in einen Zustand gebracht werden, in dem sie als Production-Ready bezeichnet werden kann.

== Mehrwert dieser Arbeit

Es ist nicht so lange her, dass "Performance Engineering" daraus bestand, die Hardware auf dem neusten Stand zu halten.
Heutzutage wird es allerdings immer schwerer, sich auf ständige verbesserung der Leistung von Prozessoren zu verlassen, um den steigenden Leistungsanforderungen der digitalisierten Welt gerecht zu werden.
Die in dieser Arbeit vorgeschlagene Architektur für In-Memory-Datenbanken bietet möglicherweise einen Ansatz für das Entwickeln von Systemen, die bei gleichbleibender Hardware effizienter arbeiten können als bisherige.

= Quellcodeverweis

Der gesamte Code, alle Grafiken, Benchmarkergebnisse und Scripts des Projekts können auf #link("https://github.com/worldOneo/smade-db")[GitHub] #footnote[https://github.com/worldOneo/smade-db] eingesehen werden.
Für die Replizierbarkeit der Ergebnisse ist es wichtig zu beachten, den Stand des Quellcodes zum Zeitpunkt der Tests zu betrachten, da die Datenbank nach den Tests weiterentwickelt wurde.

// #figure( image("./benchmark-results/round-3-intel-full-atillery/Limits of memtier.png"), caption: [Memtier performance Problem]) <fig-memtier-performance-limit>

#pagebreak()

#bibliography("biblio.yaml", style: "deutsche-sprache")

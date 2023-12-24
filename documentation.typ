#import "info.typ" as info
#import "@preview/algorithmic:0.1.0"
#import algorithmic: algorithm
#import "@preview/bob-draw:0.1.0": render

#set text(lang: "de", font: "Times New Roman", size: 11pt)
#let title = [Share Everything - Eine andere Architektur für Datenbanken]

#set page(header: [
  #info.name #h(1fr) #title #h(1fr) 2024
], footer: [
  #h(1fr) #counter(page).display("1/1", both: true) #h(1fr)
], margin: (x: 2.5cm, y: 2cm))

#set quote(block: true)
#set heading(numbering: "1.1")


#linebreak()

#align(center, text(17pt)[
  *#title*
])

#align(center)[#info.name]

#text(15pt)[
  *Kurzfassung*
]

Ziel dieses Projektes ist es die Shared Nothing Architektur, die in vielen Computersystemen genutzt wird, kritisch im gebiet der Datenbanken zu betrachten.
Hierbei steht besonders die dazu orthognal Share Everything Architektur im Fokus, in der eine alternative Datenbank implementiert wird.
Diese alternative Datenbank wird mit verbreiteten Datenbanken verglichen um die Anwendbarkeit dieser Architektur zur ermitteln.

Zentrale Aspekte der Arbeit sind dabei:
  - Die implementierung von effizienten Concurrency-Primitiven
  - Ein Algorithmus für die Umsetzung von vielschrittigen Transaktionen
  - Das effiziente Bearbeiten von parallelen Operationen über mehrere Kerne

Und diese drei Punkte zusammen in einer Datenbank unter zu bringen und mit anderen Datenbanken vergleichen.  



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

Viele Datenbanken berufen sich heutzutage auf eine "Shared Nothing Architecture" um ihre Performance Ziele und das Design der Datenbanken zu legitimieren.
In dieser Arbeit wird das gegenteilige design betrachtet "Share Everything" um zu untersuchen, inwiefern dieses Vergleichbar ist und welche Vor- und Nachteile es mit sich bringt.
Hierfür wird eine Redis kompatible alternative mit diesem Orthogonalem design implementiert und dieses verglichen mit bestehenden Redis kompatiblen Datenbanken. 

Ein weitere Fokus ist auch die Diskussion über eine weite verbreitung dieses Designs und in welchen Anwendungsfällen es in frage kommt.

= Motivation und Fragestellung

Die Shared Nothing Architektur ist weit verbreitet und kann schon beinahe als Status quo der modernen Datenbankentwicklung gesehen werden.
Interresant in dieser Situation ist allerdings, dass obwohl, oder eventuell gerade weil, viele DBs in diesem Style umgesetzt wurden gibt es nur wenige Auseinandersetzungen mit dieser Idee.

Um eine Diskussionsgrundlage zu schaffen und eine Referenz ist es notwendig vergleichbare Werte zu schaffen, anstatt sich auf die Versprechen der Share Nothing Architektur zu verlassen.
Die Frage die sich hierbei stellt ist: Inwiefern ist eine Share Everything Architektur im vergleich zur Shared Nothing Architektur sinvoll?

= Hintergrund und theoretische Grundlagen

== Cache, Lock und Resource Contention

Das grundlegende Problem bei skalierbaren Datenbanken ist das Problem der "Resource Contention."
Hierbei geht es hauptsächlich darum, dass es eine geteilte Resource gibt, auf die von mehreren Kernen zugleich zugegriffen werden könnte.
Bei typischen Programmen sind oft Speicher und Locks die wichtigsten Resourcen die geteilt werden.
Wird auf ähnliche Speicheradressen von unterschiedlichen Kernen zugegriffen so muss der Prozessor diesen Zugriff so koordinieren, dass der Speicher kohärent bleibt was besonders bei Atomic Operationen aufwendig sein kann.

Im allgemeinen kann gesagt werden, dass umso weniger Contention stattfindet, umso effizienter kann ein einzelner Kern arbeiten.

== Shared Nothing

Share Nothing basiert auf der Idee, dass es sehr effizient ist, keine Synchronisation von Daten oder von Zugriffen auf Daten zu benötigen.
In dieser Architectur werden nähmlich keine Daten zwischen mehreren Prozessen geteilt was dazu führen soll, dass nicht nur der Programmfluss vereinfacht wird,
sondern Programme auch effizienter Arbeiten können.
So muss die CPU, Beispielsweise, weniger Arbeit in Cache-Coherency oder in Atomic Operationen stecken, wenn es keinen geteilten Arbeitsspeicher gibt.
Auch soll so die Skalierbarkeit von Anwendungen erhöht werden, da die angesprochenen Probleme tendenziell mit höheren Zahlen an CPU Kernen nur größer werden. @the-case-for-shared-nothing

== Share Everything

Gegenüber diesem Share Nothing Design steht das Share Everything Design.
Das zu lösende Problem ist Ähnlich allerdings die Lösung umgekehrt.
Nimmt man an, dass kein Speicher zwischen CPU Kernen geteilt werden soll so muss es eine direkte Kommunikation zwischen den Kernen geben, wenn nicht geteilte Daten von einem einzelnem Kern benötigt werden.
Dies kann einen Overhead haben in der Kommunikation.
Muss CPU Kern A insgesammt 3 Datensätze lesen muss dieser eventuell mit 3 verschiedenen CPU Kernen kommunizieren, was 6 Nachrichten (3x hin und 3x zurück) bedeutet.
Diese Kommunikation passiert über "Channels".
Die Informationen von den Channels sind geteilt und können daher ein synchronisations Overhead bedeuten.
Das Share Everything Design zielt darauf ab, diese Kommunikation zu reduzieren und mit günstigen synchronisations Primitiven in den Daten selber die Korrektheit von Transaktionen zu garantieren.
Hierbei wird eine bedingte Cache und Lock contention beim Zugriff auf die eigentlichen Daten gegen den definitiven Kommunikationsoverhead vom Shared Nothing Design abgewogen.

= Vorgehensweise, Materialien und Methoden

Um die Fragen zu beantworten habe ich eine Datenbank implementiert, die in ihrer Funktionalität vergleichbar ist mit den existierenden Datenbanken  Redis @redis gewählt und die Alternativimplementation Dragonfly @df.
Redis dient hierbei als Vergleich für eine Architektur mit nur einem Kern und Dragonfly für eine Shared-Nothing-Architektur die mit mehreren Kernen skalieren kann.

Bei diesen Datenbanken handelt es sich um Key-Value Datenbanken@redis-kv die sich aufgrund ihrer Einheitlichkeit gut für einen Vergleichen eignen.
Eine Key-Value Datenbank kann vereinfacht als eine Hashmap über das Netzwerk beschrieben werden und ich werde daher Begriffe die mit Hashmaps assoziiert sind in bezug auf die Datenbanken nutzen. 

== Programmiersprache

Für die Implementation der Datenbank habe ich verschiedene Programmiersprache in betracht gezogen.
Da die Datenbank vergleichbar sein muss mit Redis und Dragonfly muss sie in einer vergleichbaren Sprache umgesetzt werden, die nicht zusätzliche Hürden wie einen Garbage Collector oder JIT Compiler einführt.

Die Sprachen die Sinvoll schienen waren C, C++, Rust@rust, und Zig@ziglang.
Ich habe mich für Zig entschieden, da sie recht simple ist im Vergleich zu C++, generische Typen erlaubt im Gegensatz zu C, und nicht so viele Probleme bereitet wie Rust wenn es darum geht, Daten willkürlich zwischen mehreren Threads zu Teilen.

== Dash <ch-dash>

Um einen parallelen Zugriff zu ermöglichen habe ich mich an dem Design von Dash@dash orientiert.
Auch Dragonfly orientiert sich an diesem Design doch nutzt Dragonfly Dash nicht um parallelen Zugriff zu ermöglichen sondern um einen effizienten Speicher auf einem Kern bereit zu stellen.@df-dash
Dash ist eine Datenstruktur die auf Extendible-Hashing basiert und für parallelen Zugriff optimiert ist ins besondere darauf, dass möglichst wenig Speicher geschrieben werden muss.
Da Dash allerdings eine Recht ausführliche Datenstruktur ist habe ich es mir erlaubt diese an mehreren stellen zu vereinfachen.

=== Buckets

Dash beschreibt, wie Buckets Implementiert werden können doch habe ich meine Buckets anders implementiert, um diese einfach und effizient zu gestallten.
Ein Bucket hat dabei maximal 16 Einträge.
Für jeden Eintrag gibt es 16bit an Zusatzdaten und ein 32bit Expiry-Zeitpunkt.
Die Zusatzdaten, Expiry-Zeitpunkte, und Einträge sind dabei alle jeweils in einem kontinuirlichen Array abgebildet.
Das ist daher wichtig, dass so die Zusatzdaten und Expiry-Einträge mit Vektoroperationen durchsucht werden können. 
In @layout-bucket ist dieses Layout einmal aufgezeigt.

#figure(
  table(columns: (1fr,), stroke: none, row-gutter: 5pt,
    math.overbrace(table(columns: (1fr, 1fr, 0.7fr, 1fr),[Meta1],[Meta1],$dots$,[Meta16]), "16x2bytes"),
    math.overbrace(table(columns: (1fr, 1fr, 0.7fr, 1fr),[Expiry1],[Expiry2],$dots$,[Expiry16]), "16x4bytes"),
    math.overbrace(table(columns: (1fr, 1fr, 0.7fr, 1fr),[Entry1],[Entry2],$dots$,[Entry16]), "16x48bytes"),
  ), caption: "Memory Layout eines Buckets", supplement: "Layout") <layout-bucket>

Alle Daten eines Eintrages, zum Beispiel Eintrag1/Entry1, ergeben sich aus dem Betrachten der dazugehörigen Expiry und Zusatzdaten, also Meta1 und Expiry1. 
Die Zusatzdaten bestehen aus einem 15bit Fingerabdruck des Eintrages und einem Bit der angiebt, ob der Eintrag hier existiert.
Der Fingerabdruck sind dabei einfach die letzten 15bit des Hashes des Keys des Eintrages.

In @algo-bucket-find wird beschrieben, wie ich Vektoroperationen nutze um effizient die Indizes der Einträge finde, wenn ein Hash von einem gesuchten Eintrag gegeben ist.
Es werden für die Zusatzdaten in einem Vektor mit den Dimensionen $16 "Einträge" times 2 "Byte"$ genutzt.
Dabei werden die existierenden Zusatzdaten mit dem Fingerabdruck des Eintrags verglichen nachdem gesucht wird.
Alle Indizes des Vektors wo die Fingerabdrücke des Eintrags der Suche gleich die dem Eintrags in dem Bucket sind werden mit einem Integer der Form $1 << n$ gefüllt.
Hierbei ist $n = 15-"index"$.
Wird dieser Vektor dann mit einer "Or"-Operation zu einem 16bit integer Reduziert befinden sich mögliche Indizes immer in den Indezies, wo der 16bit Integer eine 1 hat.
In Kombination mit der "Count-Leading-Zeros" Operation von modernen CPUs kann das sehr effizient umgesetzt werden.

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
Da die Expiry-Daten allerdings 4byte groß sind und das Verarbeiten von allen auf einmal 512bit Vektor Unterstützung bräuchten habe ich mich dazu entschieden, die Expiry Daten in 2 Schritten mit jeweils 8 Einträgen abzuarbeiten, da 256bit Vektoreinheiten deutlich weiter verbreitet sind als 512bit Vektoreinheiten in x64 CPUs.

=== SmallMap

18 Buckets werden in eine "SmallMap" zusammengefasst.
18 Kommt daher, da die SmallMaps damit sehr gut in die Allocator-Page meines Allocators (siehe @ch-alloc) passen. 
Die SmallMaps werden dann als Baustein genutzt um Dash aufzubauen und damit Extendible-Hashing zu betreiben.

Eine SmallMap dient als kleinste Einheit von Transaktionen in der Datenbank und ist daher mit einem Lock versehen (siehe @ch-queue für die Details des Locks).
Auf die SmallMap können Leseoperationen mit Optimistic-Concurrency durchgeführt werden und nur für Schreiboperationen muss das Lock tatsächlich gesperrt werden.

=== Vergrößern der Datenbank <ch-extend>

Auch beim vergrößern der Datenbank weiche ich von Dash ab.
Im gegensatz zu Dash wird beim starten der Datenbank ein Limit an SmallMaps festgelegt.
Damit wird die Directory, die alle SmallMaps speichert im Style von Extendible-Hashing, direkt am Anfang mit der maximalen Größe reserviert.
Das verhindert nicht nur Latenz-Spikes, die aufgrund von unerwarteten Speicherreservirungen auftreten könnten, sondern ist so das Vergrößern auch deutlich einfacher.
In @abb-dict-extension1 ist beispielhaft einmal eine Datenbank dargestellt, die auf 2 SmallMaps zeigt.

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
```), caption: [Directory for der Vergrößerung]
) <abb-dict-extension1>

Wenn die SmallMap 2 zu klein ist um Daten zu Speichern dann wird das Directory erst erweitert wie in @abb-dict-extension2.
Hierbei werden die Pointer des Directories auf die bereits existierenden SmallMaps gesetzt.
Danach wird die SmallMap aufgeteilt in eine neue SmallMap.
In @abb-dict-extension3 wird veranschaulicht, wie die SmallMap 3 hinzugefügt wird und somit die Kapazität erhöht wird.

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

Im unterschied zu Dash, da ich bereits die gesamte Größe des Directories reserviert habe, können alle Operationen bis auf die, die es erfordern, dass eine SmallMap aufgeteilt wird normal fortfahren wärend das Directory erweitert wird.
So werden die meisten Lese- und Schreiboperationen nicht blockiert.

Damit verhindert wird, dass zwei Threads zur gleichen Zeit versuchen die Datenbank zu Vergrößern gibt es ein Flag, die mit Atomic-Operationen behandelt wird, gesetzt.
Die Flag gibt an, dass die Datenbank aktuell vergrößert wird.

== Darstellung von Datenbank-Werten

Alle Werte, die in der Datenbank gespeichert werden haben das Format, welches in @layout-dbvalue dargestellt wird und insgesammt 24byte groß ist.

#figure(
  [#table(columns: (auto,1fr,), stroke: none, row-gutter: 5pt, align: left,
    [String], [#math.overbrace([`CCCCCCCC`], "Capacity")#math.overbrace([`LLLLLLLL`], "Length")#math.overbrace([`PPPPPPPP`], "Pointer")],
    [Short-String], [#math.overbrace([`DDDDDDDDDDDDDDDDDDDDDD`], "Data")`LF`],
    [Liste], [#math.overbrace([`PPPPPPPP`], "Pointer")#math.overbrace([`LLLLLLLL`], "Length")#math.overbrace([`UUUUUUU`], "Unused")`F`],
    [Andere], [#math.overbrace([`PPPPPPPP`], "Pointer")#math.overbrace([`UUUUUUUUUUUUUU`], "Unused")`FF`],
  )
  `F` entspricht "Flag" und speichert, um welchen Datentyp es sich handelt.
  ], caption: "Datenbank-Werte", supplement: "Layout"
) <layout-dbvalue>

Hierbei handelt es sich um einen Union-Type, der 3x8byte groß ist, wobei die letzten beiden Bits genutzt werden, um die Typen der Union zu unterscheiden.
Das geht, weil alle Daten von Strings in der Datenbank 8byte alligned sind und daher die letzten beiden Bits eines gültigen Pointers immer 0 sind.
Sind die letzten beiden Bits 0, so handelt es sich also um einen String.
Ist der letzte Bit 1, so handelt es sich um einen "Short-String", der seine Daten in der Datenstruktur selber speichert anstatt als auf dem Heap.
Ein Short-String kann bis zu 22bytes lang sein.
Sind die letzten beiden Bits 1, so sind andere Datentypen beschrieben.
Das kann eine (Linked-)Liste sein, die nur 2 der 8 byte Felder braucht, um den Head als auch ihre Länge zu speichern oder auch viele andere Datentypen.

== Memory-Management <ch-alloc>

Für das Memory Management habe ich als Grundlage eine vereinfachte Version von Microsofts mimalloc@mimalloc implementiert.
Das ist notwendig nicht nur aus dem Grund, dass Zig noch keinen starken und allgemeinen Allocator bereitstellt, sondern auch daher, dass ich aufgrund der Share Everything Architektur besondere Anforderungen an mein Memory-Management habe.

In der Share Everything Architektur stellt sich nämlich im Gegensatz zur Shared Nothing Architektur die Frage, wann es sicher ist, Speicher wieder an das Betriebssystem zurück zu geben.
Das Problem ist nämlich, dass ich aufgrund von der Verwendung von Optimistic-Concurrency gleichzeitig einen schreibenden und mehrere lesende Threads auf der gleichen Speicheradresse haben kann.
Würde der schreibende Thread die Speicheradresse wieder zurück an das Betriebssystem geben, während ein lesender Thread noch die Daten liest, würde es zu Fehlern kommen.
Um dieses Problem zu lösen, habe ich mich dazu entschieden, dass kein Speicher jemals an das Betriebssystem zurückgegeben wird, sondern beim Start der Datenbank eine feste Menge an Speicher angegeben wird und von der Datenbank verwendet wird.

Wenn ein schreibender Thread entscheidet, Speicher freizugeben, wird dieser nur an den Allocator gegeben, der den Speicher nicht an das Betriebssystem zurückgibt, aber wieder genutzt wird, wenn ein Thread wieder Speicher benötigt.

== Concurrency und I/O

Meine umsetzung der Datenbank orientiert sich an modernen Concurrency und I/O modellen und nutzt für Concurrency State-Machines und für I/O die asynchrone API io_uring@io-uring.
Da ich meine Datenbank in der Programmiersprache Zig implemtiere und diese zu diesen Zeitpunkt noch keine fertige untertützung für async/await hatte habe ich mich dazu entschieden, Concurrency mit der Hilfe von State-Machines zu implementieren.
Diese State-Machines werden in einem Event-Loop pro Thread immer wieder aufgerufen und können so schrittweise Fortschritt erreichen, ohne den Thread durchgängig zu blockieren.
So kann eine State-Machine die Versucht ein Lock zu Sperren speichern, dass die State-Machine an diesem Punkt weiter machen muss und die Kontrolle zurück an den Event-Loop geben, der die State-Machine zu einem späteren Zeitpunkt wieder Aufruft.

== Queue Lock <ch-queue>

Um die Latenz der Datenbank vorhersehbar zu gestallten ist es wichtig, dass keine Operation theoretisch unendlich lang dauer kann.
Da Locks aber teilweise Notwendig sind um eine effiziente Arbeitsweise zu ermöglichen habe ich das Queue-Lock entwickelt was dazu dient,
dass alle Schreiboperation in der selben Reihenfolge passieren in der sie das erste mal Probiert wurden.
Das soll verhindern, dass wenn es eine Operation auf der Datenbank gibt, die immer wieder versucht das Lock für Schreiboperationen zu Sperren, dass diese nicht von immer neuen Operationen geblockt werden kann.
So könnte es sein, dass es einen Thread gibt, der es immer wieder schafft das Lock für sich zu sperren und damit immer einen anderen Thread aussperrt.

Daher habe ich ein Locking mechanismus entworfen, der dieses Problem umgehen soll: das "Queue-Lock".
Bei dem Queue-Lock gibt es die garantierte Reihenfolge, was in @algo-queue-lock und @algo-queue-trylock beschrieben wird.
Hierbei wird ein 64bit Intger als lock genutzt wie zwei 32bit Integern ($l 32 eq.est $ Low 32 bits und $h 32 eq.est $ High 32 bits).
Das Queue-Lock kann als Warteschlange betrachtet werden, daher auch der Name.
In den high 32 bits wird gespeichert, wie viele noch vor einem in der Schlange stehen und in den low 32 bits wird gespeichert, der wie vielte gerade drann ist.
Wenn sich ein Thread in die Schlange einreiht (die high 32 bits erhöhen um 1) gibt es zwei Möglichkeiten: Entweder ein anderer Thread ist vor dem eigenen Thread, oder nicht.
Hierbei gilt auch als "vor dem eigenen Thread", wenn ein Thread gerade an der Reihe ist.
Wenn jemand gerade vor einem ist kann man regelmäßig prüfen, ob so viele nun an der Reihe waren (siehe @algo-queue-trylock).
Wenn niemand vor einem ist, ist man selber an der Reihe.
So kommt ein Thread garantiert dazu, das Lock zu Sperren. 

#algo({
    import algorithmic: *
    Function("QueueLock-WLock", args: ("lock",), {
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

#algo({
    import algorithmic: *
    Function("QueueLock-Unlock", args: ("lock",), {
      Assign([old], FnI[Atomic IncrL32+DecH32][lock])
      If(cond: "old.l32 > ROLLOVER", {
        FnI[AtomicDecr][lock, ROLLOVER]
      })
    })
}, caption: [QueueLock-Unlock]) <algo-queue-unlock>

Optimistic-Concurrency ist mit diesem Lock einfach, in dem zu begin einer Lesenden operation die unteren 32bit des 64bit Locks als Version gespeichert werden.
Ist die Version ungerade so ist das Lock gerade in einem schreibendem Modus gesperrt und die Lesende operation muss warten.
Ist die Version gerade so kann die lesende Operation beginnen.
Wenn die lesende Operation fertig ist muss sie nur die gespeicherte Version mit den unteren 32bit des Locks vergleichen.
Sind diese unterschiedlich so muss die lesende Operation neu starten; sind sie gleich, so war die Operation erfolgreich.

== Vielschrittige Transaktionen

Vielschrittige Transaktionen sind Datenbankoperationen, die in einer Transaktion mehrere Operationen so ausführen, dass sie für den Rest der Datenbank als eine einzige Operation wirken.
Wenn eine Transaktion beispielsweise die Schritte beinhaltet "Setze A auf 1 und B auf 2" und A und B vorher 0 wahren, so gibt es keinen Zeitpunkt an dem A als 1 und B als 0 oder A als 0 und B als 2 gelesen werden kann.
Es kann nur A als 0 und B als 0 oder A als 1 und B als 2 gelesen werden.

Damit solche Transaktionen in einer Datenbank effizient koordiniert werden, wird oft auf Lock-Manager wie VLL @vll, der auch in Dragonfly genutzt wird, zurückgegriffen.
Auf der Suche nach einem angemessenen Lock-Manager ist mir aufgefallen, dass nur wenige für meine gewählte Architektur passend sind und diese oft deutlich mehr Funktionalität mitbringen als ich benötige.
Daher habe ich mich dazu entschieden, ein eigenes Transaktionsscheme zu entwickeln, welches möglichst gut auf meine Datenbank passt.

Mein Transaktionsschema funktioniert so:
  + Alle SmallMaps, die für die Transaktion benötigt werden, werden als Pointer aus dem Directory geladen und in ein Array gespeichert.
  + Die SmallMaps werden nach ihrem Pointerwert in aufsteigender Reihenfolge sortiert.
  + Die Locks der SmallMaps werden in der Reihenfolge nun aufsteigend gesperrt. Es kann passieren, dass eine Falsche SmallMap gesperrt wird, da zwischen Punkt 1 und dem Sperren der SmallMap der Wert, der für die Transaktion erforderlich ist, nach dem in @ch-extend beschrieben Verfahren, nun in einer anderen SmallMap ist, dann wird die falsch gesperrte SmallMap einfach wieder entsperrt und die richtige SmallMap gesucht und in das sortierte Array an die richtige stelle eingefügt. 

Bei Punkt 3 ist anzumerken, dass alle bereits gesperrten Pointer, die einen größeren Wert haben als der neu geladene, wieder entsperrt werden müssen, um Deadlocks zu vermeiden.

Diese Art vielschrittige Transaktionen zu machen ist sicher vor Deadlocks, da die SmallMaps immer in aufsteigender Reihenfolge gesperrt werden.
Intuitiv ist das schlüssig und es lässt sich auch durch einen einfachen Beweis durch Widerspruch zeigen, das Deadlocks so vermieden werden:
  + Nehmen wir an, es gibt ein Deadlock, so muss dieser entstehen, weil ein Thread #1 auf eine SmallMap wartet, die ein anderer Thread #2 gesperrt hat und Thread #2 wartet auf eine SmallMap die Thread #1 gesperrt hat.
  + Alle SmallMaps die ein Thread sperrt werden in einer aufsteigenden Reihenfolge gesperrt.
  + Thread #1 wartet auf eine SmallMap $s_1$, die größer ist, als alle bereits gesperrten.
  + Thread #2 wartet auf eine SmallMap $s_2$, die größer ist, als alle bereits gesperrten.
  + Thread #1 wartet auf $s_1$, die von Thread #2 gesperrt ist und größer ist als alle bereits gesperrten von Thread #1 aber Thread #2 wartet auf $s_2$, die von Thread #1 gesperrt aber aufgrund der Reihenfolge.
  + Da Thread #2 $s_1$ gesperrt hat und $s_2$ sperren will muss $s_1 < s_2$, da Thread #1 $s_2$ gesperrt hat und $s_1$ sperren will muss also auch $s_2 < s_1$ gelten.
  + Daraus folgt: $s_1 < s_2 < s_1$ was ein Widerspruch ist und daher nicht auftreten kann.

== Performance messen und vergleichen <ch-messen>

Das Messen der Performance hat sich als schwieriger als erwartet herausgestellt.
Nicht nur ist es der Fall, dass es keinen verbreitetn Test für Transaktionen gibt, sondern auch, dass das oft genutzte Tool "Memtier", dass von Redis eingeführt und entwickelt wurde zum testen von Datenbanken@memtier , sich als weniger Skalierbar als meine implementation der Datenbank heraustellt und daher keine festen Ergebnisse liefern konnte.
Um dieses Problem zu umgehen habe ich zusätzlich ein Tool namens "Loader" implementiert, dass die Aufgabe des Messens übernehmen soll.

Aber was wird überhaupt gemessen?
Drei Metriken sind besonders wichtig beim betrachten von Architekturunterschieden zwischen Datenbanken:
  - Latenz
  - Durchsatzleistung
  - Skalierbarkeit

Hierbei ist zu beachten, dass Zwar im Allgemeinen oft $"Latenz" prop 1 / "Durchsatzleistung"$ gilt, dass aber nicht der Fall sein muss für viele Designs und die Latenz ja auch für diverse Perzentile betrachtet werden sollte.
Für den Vergleich habe ich also diese Metriken ausgewählt in diesen Einheiten:
  
  - Latenz in $mu s$ für Durschnitt, p50, p80, p90, p99, p99.9, p99.995, und p99.999
  - Durchsatzleistung in Queries pro Sekunde (QPS)
  - Skalierbarkeit in $%$. Sie ergibt sich aus der folgenden Rechnung: $"Skalierbarkeit" = "QPS mit N Kernen"/"QPS mit 1 Kern"$

Gemessen wurden diese Metriken so:

Als erster wird ein Threadpool gestartet und jeder Thread verbindet sich mit einer festen Anzahl an Verbindungen mit der jeweiligen Datenbank.
Sobald eine Verbindungen verbunden ist startet diese Anfragen an die Datenbank zu schicken mit einem festgelegten Format.
Das passiert so lange, bis jede Verbindung Anfragen schickt und dann geht das Messen los, wobei 20 Sekunden lang gemessen wird.
Für jede Anfrage wird die Latenz gemessen und gespeichert.
Die Durchsatzleistung ergiebt sich nach den 20 Sekunden aus den gesammt gemessenen Anfragen geteilt durch 20 Sekunden.
Die Latenz-Metriken (Durchschnitt, p50 etc. etc.) ergeben sich aus der Agregation von den gespeicherten Latenzen.

Dieser Test wird für die Datenbanken mit unterschiedlichen Anzahl an Kernen durchgeführt woraus die Skalierbarkeit abgelitten werden kann.

= Ergebnisse

Die Tests wurden wie in @ch-messen beschrieben durchgeführt auf AWS Ubuntu Instanzen mit 32 Kernen und 64 Virtuellen Kernen.
Für eine hohe Vergleichbarkeit wurden alle Tests und alle Datenbanken auf der selben AWS Instanz getestet um Probleme wie Temperaturschwankungen, Golden Samples, oder Noisy-Neighbours zu vermeiden.

= Ergebnissdiskussion

= Fazit und Ausblick


// #figure( image("./benchmark-results/round-3-intel-full-atillery/Limits of memtier.png"), caption: [Memtier performance Problem]) <fig-memtier-performance-limit>

#pagebreak()

#bibliography("biblio.yaml")

#set page(columns: 1)

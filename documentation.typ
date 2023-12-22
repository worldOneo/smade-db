#import "info.typ" as info
#import "@preview/algorithmic:0.1.0"
#import algorithmic: algorithm

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

Share Nothing basiert auf der Idee, dass es sehr effizient ist, keine Synchronisation von Daten oder die Zugriffe auf diese Daten zu benötigen.
In dieser Architectur werden nähmlich keine Daten zwischen mehreren Prozessen geteilt was dazu führen soll, dass nicht nur der Programmfluss vereinfacht wird,
sondern sich auch näher an der Hardware orientiert.
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

Um die Fragen zu beantworten habe ich eine Datenbank implementiert, die in ihrer Funktionalität vergleichbar ist mit existierenden Datenbanken.
Ich habe als Datenbank Redis@redis gewählt und die Alternativimplementation Dragonfly@df
Redis dient hierbei als vergleich für eine einfach Kern Architektur und Dragonfly führ eine Shared-Nothing-Architektur die mit mehreren Kernen skalieren kann.

== Programmiersprache

Für die Implementation der Datenbank habe ich verschiedene Programmiersprache in betracht gezogen.
Da die Datenbank vergleichbar sein muss mit Redis und Dragonfly muss sie in einer vergleichbaren Sprache umgesetzt werden, die nicht zusätzliche Hürden wie einen Garbage Collector oder JIT Compiler einführt.

Die Sprachen die Sinvoll schienen waren C, C++, Rust@rust, und Zig@ziglang.
Ich habe mich für Zig entschieden, da sie recht sicher und intuitiv ist im Vergleich zu C und C++, generische Typen erlaubt im Vergleich zu C, und nicht so viele Probleme bereitet wie Rust wenn es darum geht, Daten willkürlich zwischen mehreren Threads zu Teilen.

== Dash <ch-dash>

Um einen parallelen Zugriff zu ermöglichen habe ich mich an dem Design von Dash@dash orientiert.
Auch Dragonfly orientiert sich an diesem Design doch nutzt Dragonfly Dash nicht um parallelen Zugriff zu ermöglichen sondern um einen effizienten Speicher auf einem Kern bereit zu stellen.@df-dash
Dash ist eine Datenstruktur die auf Extendible-Hashing basiert allerdings für parallelen Zugriff optimiert ist und ins besondere darauf, dass möglichst wenig Speicher geschrieben werden muss.
Da Dash allerdings eine Recht ausführliche Datenstruktur ist habe ich es mir erlaubt diese an mehreren stellen zu vereinfachen.

== Concurrency und I/O

Meine umsetzung der Datenbank orientiert sich an modernen Concurrency und I/O modellen und nutzt für Concurrency, aufgrund von mangel an async/await support, State-Machines und für I/O die asynchrone API io_uring@io-uring.
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
Wenn sich ein Thread in die Schlange einreiht (die high 32 bits erhöhen um 1) gibt es zwei Möglichkeiten: Entweder jemand ist vor dir, oder nicht.
Hierbei gilt auch als "jemand vor dir", wenn jemand gerade an der Reihe ist.
Wenn jemand gerade vor einem ist kann man regelmäßig prüfen, ob so viele nun an der Reihe waren (siehe @algo-queue-trylock).
Wenn niemand vor einem ist, ist man selber an der Reihe.
So kommt ein Thread garantiert dazu, das Lock zu Sperren. 

#algo({
    import algorithmic: *
    Function("QueueLock-WLock", args: ("lock",), {
      Assign([old], FnI[AtomicIncr][lock.h32])
      Assign([slot], [old.h32])
      Assign([pos], [old.l32])
      If(cond: "slot+pos >= ROLLOVER", {
        Assign([slot], [slot - ROLLOVER])
      })
      If(cond: "slot = pos", (
        FnI("AtomicIncr", "lock.l32"),
        Return([Acquired])
      ))
      Else(Return([Queued: slot+pos]))
    })
}, caption: [QueueLock-Lock]) <algo-queue-lock>

#algo({
    import algorithmic: *
    Function("QueueLock-LockSlot", args: ("lock", "slot",), {
      Assign([old], FnI[AtomicLoad][lock])
      If(cond: "slot = old.l32", {
        Return[Acquired]
      })
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
  - Skalierbarkeit in $%$. Sie einheit Ergibt sich aus der folgenden Rechnung: $"Skalierbarkeit" = "QPS mit N Kernen"/"QPS mit 1 Kern"$

Gemessen wurden diese Metriken so:

Als erster wird ein Threadpool gestartet und jeder Thread verbindet sich mit einer festen Anzahl an Verbindungen mit der jeweiligen Datenbank.
Sobald eine Verbindungen verbunden ist startet diese Anfragen an die Datenbank zu schicken mit einem festgelegten Format.
Das passiert so lange, bis jede Verbindung Anfragen schickt und dann geht das Messen los, wobei 20 Sekunden lang gemessen wird.
Für jede Anfrage wird die Latenz gemessen und gespeichert.
Die Durchsatzleistung ergiebt sich nach den 20 Sekunden aus den gesammt gemessenen Anfragen geteilt durch 20 Sekunden.
Die Latenz-Metriken (Durchschnitt, p50 etc. etc.) ergeben sich aus der Agregation von den gespeicherten Latenzen.

Dieser Test wird für die Datenbanken mit unterschiedlichen Anzahl an Kernen durchgeführt woraus die Skalierbarkeit abgelitten werden kann.


= Ergebnisse

= Ergebnissdiskussion

= Fazit und Ausblick


// #figure( image("./benchmark-results/round-3-intel-full-atillery/Limits of memtier.png"), caption: [Memtier performance Problem]) <fig-memtier-performance-limit>

#pagebreak()

#bibliography("biblio.yaml", style: "cell")
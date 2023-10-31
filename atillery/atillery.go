package main

import (
	"bytes"
	"fmt"
	"log"
	"math/rand"
	"net"
	"sync"
	"time"

	"github.com/HdrHistogram/hdrhistogram-go"
)

const clients = 48
const requestsPerClient = 50_000

const minKey = 1_000_000
const maxKey = 9_999_999
const setPerTransaction = 5

const okBytes = 5
const queuedBytes = 9

const listHead = 2

// const recvBytes = okBytes + queuedBytes*setPerTransaction + listHead + okBytes*setPerTransaction // Dragonfly
const recvBytes = okBytes + setPerTransaction*queuedBytes + okBytes // smade

// const port = 6379 // Redis + Dragonfly
const port = 32781 // smade for some reason

func stress(port uint16, out chan *hdrhistogram.Histogram) {
	connection, err := net.Dial("tcp", fmt.Sprintf("localhost:%d", port))
	if err != nil {
		log.Panic("Failed to dial: ", err)
	}

	send := bytes.Buffer{}
	hist := hdrhistogram.New(1, 1_000_000, 5)

	for i := 0; i < requestsPerClient; i++ {
		send.Reset()
		send.WriteString("*1\r\n$5\r\nMULTI\r\n")
		for t := 0; t < setPerTransaction; t++ {
			send.WriteString("*3\r\n$3\r\nSET\r\n$7\r\n")
			fmt.Fprintf(&send, "%d", rand.Intn(maxKey-minKey)+minKey)
			send.WriteString("\r\n$7\r\n")
			fmt.Fprintf(&send, "%d", rand.Intn(maxKey-minKey)+minKey)
			send.WriteString("\r\n")
		}
		send.WriteString("*1\r\n$4\r\nEXEC\r\n")
		var recv [recvBytes]byte
		now := time.Now().UnixMicro()
		connection.Write(send.Bytes())

		recvd := 0
		for recvd < recvBytes {
			r, err := connection.Read(recv[:])
			if err != nil {
				log.Panicf("Failed to read: %s : %v", string(recv[:]), err)
			}
			recvd += r
			// fmt.Printf("read: %d to %s\n", recvd, recv)
		}

		end := time.Now().UnixMicro()
		hist.RecordValue(end - now)
	}

	out <- hist
}

func main() {
	wg := sync.WaitGroup{}
	res := make(chan *hdrhistogram.Histogram)
	hist := hdrhistogram.New(1, 1_000_000, 3)

	for i := 0; i < clients; i++ {
		go stress(port, res)
		wg.Add(1)
	}

	now := time.Now()

	for i := 0; i < clients; i++ {
		if hist.Merge(<-res) != 0 {
			log.Panicf("The number isn't 0")
		}
	}

	delta := time.Since(now)
	fmt.Printf("Reqs/Sec: %.2f [%v]\n", float64(requestsPerClient*clients)/delta.Seconds(), delta)
	fmt.Printf("p50: %d\n", hist.ValueAtPercentile(50))
	fmt.Printf("p80: %d\n", hist.ValueAtPercentile(80))
	fmt.Printf("p90: %d\n", hist.ValueAtPercentile(90))
	fmt.Printf("p99: %d\n", hist.ValueAtPercentile(99))
	fmt.Printf("p99.9: %d\n", hist.ValueAtPercentile(99.9))
	fmt.Printf("p99.99: %d\n", hist.ValueAtPercentile(99.99))
	fmt.Printf("p99.995: %d\n", hist.ValueAtPercentile(99.995))
	fmt.Printf("p99.999: %d\n", hist.ValueAtPercentile(99.999))
}

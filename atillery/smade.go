//go:build smade

package main

const recvBytes = okBytes + queuedBytes*setPerTransaction + listHead + okBytes*setPerTransaction // Dragonfly
const port = 6379

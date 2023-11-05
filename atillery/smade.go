//go:build smade

package main

const recvBytes = okBytes + queuedBytes*setPerTransaction + okBytes
const port = 32781

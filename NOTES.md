# In flight - shallow - benchmarks

## Allocator benchmark
Xt(hreads) + Yp(ools)

### Threading + Mutex
| Threads | Pools | Mops/sec |
|---|---|---|
| 12 | 24 | 24.6 |
| 12 | 12 | 22 |
| 12 | 8 | 13.3 |
| 12 | 6 | 7 |
| 6 | 24 | 19 |
| 6 | 18 | 18.5 |
| 6 | 12 | 15.6 |
| 6 | 8 | 13.3 | 
| 6 | 6 | 12 |

### State Machines + CAS Lock

| Threads | Pools | Mops/sec |
|---|---|---|
| 12 | 24 | 27.5 |
| 12 | 18 | 25.4 |
| 12 | 12 | 18 |
| 12 | 8 | 7.6 |
| 12 | 6 | 3.7 |
| 6 | 24 | 22.7 |
| 6 | 18 | 19.7 |
| 6 | 12 | 17.3 |
| 6 | 8 | 16 |
| 6 | 6 | 11.2 |
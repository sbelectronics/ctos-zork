# Notes

## Memory map of Zork.run (one segment)

| What | Where |
|---|---|
| Code, then constant data | from offset 0 |
| Variables | after the code and constants |
| `RSTBLK` | 512-byte scratch buffer used to check a save file before restoring it |
| `SAVEBLK` | 4096 bytes, written to save files: 32 bytes of state (magic `SZ`, release, serial, PC offset and chunk, `ZSP`, `ZFP`), then the Z-stack, 2032 words |
| CPU stack | 1 KB, up to `STKTOP` |

The story is in up to 4 chunks of 33,296 bytes from `AllocMemorySL`, normalised to
segment:0. `CHSEG[i]` is chunk i's segment:
- Z-machine byte address A is at `CHSEG[A >> 15]:(A & 7FFFh)`.
- The PC is kept as a (chunk, offset) pair, `PCCH`:`PCOFF`, and so is the text decoder's
  pointer, `DCH`:`DOFF`.

Z-stack frame layout, five words below `ZFP`:

| Word | Contents |
|---|---|
| `ZFP-10` | return PC offset |
| `ZFP-8` | return PC chunk |
| `ZFP-6` | store variable (`FFFFh` for none) |
| `ZFP-4` | old `ZFP` |
| `ZFP-2` | argument count |
| `ZFP` onward | the locals |

## Save file

The save file has two parts:
1. Dynamic memory (the header word at 0Eh, rounded up to 512 bytes), at file address 0;
2. `SAVEBLK` (4096 bytes).

Restore checks the magic word, the release and the first 4 bytes of the serial number
before it reads anything into memory.

## CTOS calls

The calling convention is PL/M LARGE:
- arguments are pushed left to right;
- a pointer is pushed as segment, then offset;
- a DWORD is pushed as high word, then low word;
- the callee pops the arguments.

Each wrapper in `zork.asm` keeps SI, DI, BP and ES, and reloads DS.

| Call | Address | Notes |
|---|---|---|
| OpenFile | 0000:0218 | mode `mr` = 6D72h, `mm` = 6D6Dh |
| CreateFile | 0000:021A | |
| CloseFile | FFF8:0294 | |
| ChangeFileLength | FFF8:029A | |
| GetDateTime | FFF8:029C | |
| Read | FFE0:0416 | file address and size in multiples of 512 |
| Write | FFE0:0418 | file address and size in multiples of 512 |
| AllocMemorySL | FFD8:0494 | |
| Beep | FFD0:0518 | |
| ReadKbd | FFD0:051A | RETURN (0Ah or 0Dh), BACKSPACE (08h or 7Fh) and GO (1Bh) |
| PosFrameCursor | FFDF:0432 | |
| PutFrameAttrs | FFDF:0434 | attribute 4 = reverse video |
| PutFrameChars | FFDF:0436 | |
| ResetFrame | FFDF:043A | |
| ScrollFrame | FFDF:043C | |
| GetpASCB | FFCF:053E | the ASCB, whose word at offset 2 points to the VLPB |
| ErrorExit | FFEF:0334 | |
| Exit | FFEF:0336 | |

`ResetVideo` and `InitVidMap(0:0, sMap)` leave the AWS screen blank, though they return no
error. [Rats](https://github.com/sbelectronics/rats) makes the same calls, but then rebuilds the
AWS character map itself in its `AwsDrv.asm`. Zork keeps the Executive's frames instead:
- On the AWS, frame 0 is screen lines 3-28 (26 lines).
- On the NGEN it is also below the Executive's header lines.

## Command parameters

The Executive passes the fields of a command form in the Variable-Length Parameter Block
(VLPB). `RgParam` in the CTOS library reads it, but Zork reads it directly:

| Offset | Contents |
|---|---|
| 0 | `sVarParams` |
| 2 | `ibFirstFree` |
| 4 | `cParams`, the number of fields. Parameter 0, the command, isn't counted. |
| 6 | `cParams + 1` pairs of words, one per parameter: the offset in the VLPB of its subparameters, and their length |

Each subparameter is a length byte followed by its characters. A one-field command has
`cParams` = 1, not 2. `Run` passes its `[Param n]` fields as parameters 1 to 16.

## Running it in the headless simulators

The [simulator](https://github.com/sbelectronics/aws-simulator) has headless versions of both
machines, `awssim` and `ngensim`. From its directory:

```sh
out/awssim.exe -seconds 90 -quiet -floppy /path/to/zork/dist/Zork.img -insert 35 \
  -type '30:\g;40:run\n;42:[f0]<Zork>Zork.run\g;60:open mailbox\n'

out/ngensim.exe -seconds 120 -quiet -floppy /path/to/zork/dist/Zork.img -insert 55 \
  -type '30:\n;31:\n;32:Thu Nov 5, 1987 1:00 pm;50:\g;62:run\n;66:[f0]<Zork>Zork.run\g;95:open mailbox\n'
```

Give the typed fields a few seconds between them, as typing is slower than it looks. If a
field starts before the previous one has been typed, the two run together.

On the simulated 8 MHz AWS:
- loading the 86 KB story takes about 2 seconds;
- a typical command takes about 0.2 seconds.

The windowed simulator, `awswin`, keeps a floppy's writes in `<image>.overlay` beside the
image. Delete that file after rebuilding the image, or `awswin` refuses the new one.

The Executive's `New Command` rejects a `Description` with spaces in it.

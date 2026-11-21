;  zork.asm - a Z-machine (version 3) interpreter for Convergent CTOS,
;  for playing Zork I and other version 3 games on the AWS and the NGEN.
;
;  One segment: CS = DS = SS, entered at offset 0.  CTOS is called through
;  its fixed far addresses (see the CTOS call list below), so the run file
;  needs no library and no relocations; tools/mkrun.py writes it.
;
;  The story file (Zork1.dat by default, a version 3 .z3 file) is read whole into
;  memory, in chunks of 32 KB from AllocMemorySL.  Each chunk is 512 bytes
;  longer than 32 KB and holds the start of the next one as well, so a word
;  that straddles two chunks still reads correctly.  Z-machine byte address
;  A is in chunk A / 8000h at offset A mod 8000h.  Dynamic memory (the only
;  part the game writes) is in chunk 0.
;
;  Register use: routines may change AX, BX, CX, DX and ES, and keep SI, DI
;  and BP, unless their comment says otherwise.  DS always equals CS.
;
;  Avoid the percent sign anywhere in this file except for macro calls:
;  the ASM86 macro processor takes it as a macro call even in comments.

NAME    ZORK

%*DEFINE(CALLF(ip,cs))(
        DB      9AH
        DW      %ip, %cs
)

; ---- CTOS entry points (requests and OS subroutines, fixed CS:IP)
; OpenFile        0000:0218   CreateFile      0000:021A
; CloseFile       FFF8:0294   ChangeFileLen   FFF8:029A
; GetDateTime     FFF8:029C   Read            FFE0:0416
; Write           FFE0:0418   AllocMemorySL   FFD8:0494
; ReadKbd         FFD0:051A   Beep            FFD0:0518
; ErrorExit       FFEF:0334   Exit            FFEF:0336
; PosFrameCursor  FFDF:0432   PutFrameAttrs   FFDF:0434
; PutFrameChars   FFDF:0436   ResetFrame      FFDF:043A
; ScrollFrame     FFDF:043C   GetpASCB        FFCF:053E
; ResetVideo, InitVidFrame and InitVidMap aren't used: after them the AWS
; screen stays blank, so Zork keeps the Executive's frame 0.

CHUNKSZ EQU     33280                   ; bytes read into each chunk (32 KB + 512)
CHUNKAL EQU     33296                   ; bytes allocated per chunk (16 more, to align)
MAXCHK  EQU     4                       ; 4 chunks cover the 128 KB a .z3 file may have
ZSTKSZ  EQU     4064                    ; Z-stack bytes (with the 32-byte state: 4096)
SAVESZ  EQU     4096                    ; the state block written to a save file
MODERD  EQU     6D72H                   ; 'mr' mode read
MODEMOD EQU     6D6DH                   ; 'mm' mode modify
COLS    EQU     80                      ; screen columns

ZCODE   SEGMENT PUBLIC 'CODE'
        ASSUME  CS:ZCODE, DS:ZCODE, SS:ZCODE, ES:ZCODE

; ======================================================================
;  Start
; ======================================================================
START:  CLI
        MOV     AX, CS
        MOV     DS, AX
        MOV     SS, AX
        MOV     SP, OFFSET STKTOP
        STI
        CLD
        CALL    SCRINIT
        CALL    LOADSTORY
        CALL    RNDSEED
        CALL    ZRESTART
        JMP     MAINLOOP

; ======================================================================
;  CTOS call wrappers.  Each keeps SI, DI, BP and ES, puts DS back, and
;  returns the CTOS error code in AX.
; ======================================================================

;  CPUTCH: PutFrameChars(AX=frame, BX=col, CX=line, DX=offset of text in DS, DI=count)
CPUTCH: PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    AX
        PUSH    BX
        PUSH    CX
        PUSH    DS
        PUSH    DX
        PUSH    DI
        %CALLF(0436H,0FFDFH)
CRESTO: MOV     BX, CS
        MOV     DS, BX
        POP     ES
        POP     BP
        POP     DI
        POP     SI
        RET

;  CPUTAT: PutFrameAttrs(AX=frame, BX=col, CX=line, DX=attr, DI=count)
CPUTAT: PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    AX
        PUSH    BX
        PUSH    CX
        PUSH    DX
        PUSH    DI
        %CALLF(0434H,0FFDFH)
        JMP     CRESTO

;  CPOSCUR: PosFrameCursor(AX=frame, BX=col, CX=line)
CPOSCUR: PUSH   SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    AX
        PUSH    BX
        PUSH    CX
        %CALLF(0432H,0FFDFH)
        JMP     CRESTO

;  CSCROLL: ScrollFrame(AX=frame, BX=first line, CX=line limit, DX=count, up)
CSCROLL: PUSH   SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    AX
        PUSH    BX
        PUSH    CX
        PUSH    DX
        MOV     AX, 0FFH
        PUSH    AX
        %CALLF(043CH,0FFDFH)
        JMP     CRESTO

;  CRESETF: ResetFrame(AX=frame)
CRESETF: PUSH   SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    AX
        %CALLF(043AH,0FFDFH)
        JMP     CRESTO

;  CREADKB: ReadKbd(@KBCHAR); AX = erc, KBCHAR = the character
CREADKB: PUSH   SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    DS
        MOV     AX, OFFSET KBCHAR
        PUSH    AX
        %CALLF(051AH,0FFD0H)
        JMP     CRESTO

;  CBEEP: Beep
CBEEP:  PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        %CALLF(0518H,0FFD0H)
        JMP     CRESTO

;  COPEN: OpenFile(@FHANDLE, DS:DX name, CX length, no password, BX=mode)
COPEN:  PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    DS
        MOV     AX, OFFSET FHANDLE
        PUSH    AX
        PUSH    DS
        PUSH    DX
        PUSH    CX
        PUSH    DS
        MOV     AX, OFFSET NOPASS
        PUSH    AX
        XOR     AX, AX
        PUSH    AX
        PUSH    BX
        %CALLF(0218H,0000H)
        JMP     CRESTO

;  CCREATE: CreateFile(DS:DX name, CX length, no password, size BX:AX)
CCREATE: PUSH   SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    DS
        PUSH    DX
        PUSH    CX
        PUSH    DS
        MOV     CX, OFFSET NOPASS
        PUSH    CX
        XOR     CX, CX
        PUSH    CX
        PUSH    BX
        PUSH    AX
        %CALLF(021AH,0000H)
        JMP     CRESTO

;  CCLOSE: CloseFile(AX=handle)
CCLOSE: PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    AX
        %CALLF(0294H,0FFF8H)
        JMP     CRESTO

;  CSETLEN: ChangeFileLength(FHANDLE, size BX:AX)
CSETLEN: PUSH   SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    FHANDLE
        PUSH    BX
        PUSH    AX
        %CALLF(029AH,0FFF8H)
        JMP     CRESTO

;  CREAD: Read(FHANDLE, ES:BX buffer, CX size, file address DX:AX, @IOCOUNT)
CREAD:  PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    FHANDLE
        PUSH    ES
        PUSH    BX
        PUSH    CX
        PUSH    DX
        PUSH    AX
        PUSH    DS
        MOV     AX, OFFSET IOCOUNT
        PUSH    AX
        %CALLF(0416H,0FFE0H)
        JMP     CRESTO

;  CWRITE: Write(FHANDLE, ES:BX buffer, CX size, file address DX:AX, @IOCOUNT)
CWRITE: PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    FHANDLE
        PUSH    ES
        PUSH    BX
        PUSH    CX
        PUSH    DX
        PUSH    AX
        PUSH    DS
        MOV     AX, OFFSET IOCOUNT
        PUSH    AX
        %CALLF(0418H,0FFE0H)
        JMP     CRESTO

;  CALLOC: AllocMemorySL(AX=bytes, @MEMPTR)
CALLOC: PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    AX
        PUSH    DS
        MOV     AX, OFFSET MEMPTR
        PUSH    AX
        %CALLF(0494H,0FFD8H)
        JMP     CRESTO

;  CGETDT: GetDateTime(@MEMPTR) (4 bytes)
CGETDT: PUSH    SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    DS
        MOV     AX, OFFSET MEMPTR
        PUSH    AX
        %CALLF(029CH,0FFF8H)
        JMP     CRESTO

;  CGETASCB: GetpASCB(@MEMPTR), the Application System Control Block
CGETASCB: PUSH  SI
        PUSH    DI
        PUSH    BP
        PUSH    ES
        PUSH    DS
        MOV     AX, OFFSET MEMPTR
        PUSH    AX
        %CALLF(053EH,0FFCFH)
        JMP     CRESTO

;  CEXIT: clear the frame and Exit (does not return)
CEXIT:  XOR     AX, AX
        CALL    CRESETF
CEXIT1: %CALLF(0336H,0FFEFH)
        JMP     CEXIT1

; ======================================================================
;  Screen.  Everything goes in frame 0, ROWS lines: line 0 is the status
;  line, and text goes to the bottom line, which is kept in LINEBUF (COLS
;  characters, padded with spaces) until a new line scrolls lines 1 up.
; ======================================================================

SCRINIT:
        ; frame 0's height is the first line PosFrameCursor refuses
        XOR     DX, DX
SCRI1:  PUSH    DX
        XOR     AX, AX
        XOR     BX, BX
        MOV     CX, DX
        CALL    CPOSCUR
        POP     DX
        OR      AX, AX
        JNZ     SCRI2
        INC     DX
        CMP     DX, 60
        JB      SCRI1
SCRI2:  CMP     DX, 8
        JAE     SCRI3
        MOV     AX, 1
        JMP     FATALC
SCRI3:  MOV     ROWS, DX
        XOR     AX, AX
        CALL    CRESETF
        CALL    CLRLINE
        MOV     LINELEN, 0
        MOV     MORECNT, 0
        RET

;  CLRLINE: fill LINEBUF with spaces
CLRLINE: PUSH   DI
        PUSH    DS
        POP     ES
        MOV     DI, OFFSET LINEBUF
        MOV     CX, COLS
        MOV     AL, ' '
        REP     STOSB
        POP     DI
        RET

;  SHOWLINE: draw LINEBUF on the bottom line of frame 0
SHOWLINE:
        PUSH    DI
        XOR     AX, AX
        XOR     BX, BX
        MOV     CX, ROWS
        DEC     CX
        MOV     DX, OFFSET LINEBUF
        MOV     DI, COLS
        CALL    CPUTCH
        POP     DI
        RET

;  SHOWCUR: put the cursor at LINELEN on the bottom line
SHOWCUR:
        XOR     AX, AX
        MOV     BX, LINELEN
        CMP     BX, COLS-1
        JBE     SHOWC1
        MOV     BX, COLS-1
SHOWC1: MOV     CX, ROWS
        DEC     CX
        CALL    CPOSCUR
        RET

;  SCRNL: end the bottom line: draw it, scroll frame 0 up a line, start
;  an empty one.  Pauses with [MORE] when a screenful has gone by since
;  the last input.
SCRNL:  CALL    SHOWLINE
        XOR     AX, AX
        MOV     BX, 1
        MOV     CX, ROWS
        MOV     DX, 1
        CALL    CSCROLL
        CALL    CLRLINE
        MOV     LINELEN, 0
        CALL    SHOWLINE
        INC     MORECNT
        MOV     AX, ROWS
        SUB     AX, 3
        CMP     MORECNT, AX
        JB      SCRNL9
        CALL    MOREPROMPT
SCRNL9: RET

MOREPROMPT:
        PUSH    SI
        PUSH    DI
        PUSH    DS
        POP     ES
        MOV     SI, OFFSET MOREMSG
        MOV     DI, OFFSET LINEBUF
        MOV     CX, MOREMSGL
        REP     MOVSB
        POP     DI
        POP     SI
        MOV     LINELEN, MOREMSGL
        CALL    SHOWLINE
        CALL    SHOWCUR
        CALL    GETKEY
        CALL    CLRLINE
        MOV     LINELEN, 0
        CALL    SHOWLINE
        MOV     MORECNT, 0
        RET

;  GETKEY: wait for a key; AL = its code
GETKEY: CALL    CREADKB
        OR      AX, AX
        JZ      GETK1
        ; on an error (for example no keyboard) just carry on
        MOV     AL, 0DH
        RET
GETK1:  MOV     AL, KBCHAR
        XOR     AH, AH
        RET

; ======================================================================
;  Text output with word wrap.
;  OUTCH: AL = ZSCII character.  13 is a new line.
; ======================================================================
OUTCH:  CMP     OUTMODE, 0
        JE      OUTC0
        JMP     OUTSTAT
OUTC0:  CMP     AL, 13
        JNE     OUTC1
        JMP     SCRNL
OUTC1:  CMP     AL, ' '
        JB      OUTCQ
        CMP     AL, 7EH
        JBE     OUTC2
OUTCQ:  MOV     AL, '?'
OUTC2:  MOV     BX, LINELEN
        CMP     BX, COLS
        JB      OUTC5
        ; the line is full
        CMP     AL, ' '
        JNE     OUTC3
        JMP     SCRNL                   ; a space at the end just ends the line
OUTC3:  ; move the last word to a new line
        PUSH    AX
        CALL    WRAPLINE
        POP     AX
        MOV     BX, LINELEN
OUTC5:  MOV     LINEBUF[BX], AL
        INC     BX
        MOV     LINELEN, BX
        RET

;  WRAPLINE: LINEBUF is full; break it after its last space, and carry the
;  part after it to a new line.  With no space, break at the edge.
WRAPLINE:
        PUSH    SI
        PUSH    DI
        MOV     BX, COLS
WRAP1:  DEC     BX
        JS      WRAPHARD
        CMP     LINEBUF[BX], ' '
        JNE     WRAP1
        ; BX = last space.  Save the tail in WRAPBUF.
        LEA     SI, LINEBUF[BX+1]
        MOV     CX, COLS-1
        SUB     CX, BX                  ; tail length
        MOV     WRAPLEN, CX
        PUSH    DS
        POP     ES
        MOV     DI, OFFSET WRAPBUF
        PUSH    CX
        REP     MOVSB
        POP     CX
        ; blank the tail on this line
        LEA     DI, LINEBUF[BX]
        INC     CX
        MOV     AL, ' '
        REP     STOSB
        CALL    SCRNL
        ; put the tail on the new line
        MOV     SI, OFFSET WRAPBUF
        MOV     DI, OFFSET LINEBUF
        MOV     CX, WRAPLEN
        MOV     LINELEN, CX
        PUSH    DS
        POP     ES
        REP     MOVSB
        POP     DI
        POP     SI
        RET
WRAPHARD:
        CALL    SCRNL
        POP     DI
        POP     SI
        RET

;  OUTSTAT: put AL into the status line buffer (OUTMODE 1)
OUTSTAT:
        CMP     AL, ' '
        JB      OUTS9
        CMP     AL, 7EH
        JA      OUTS9
        MOV     BX, STATPOS
        CMP     BX, COLS
        JAE     OUTS9
        MOV     STATBUF[BX], AL
        INC     STATPOS
OUTS9:  RET

;  OUTSTR: print the CX characters at DS:SI (SI ends up after them)
OUTSTR: JCXZ    OUTST9
OUTST1: LODSB
        PUSH    CX
        PUSH    SI
        CALL    OUTCH
        POP     SI
        POP     CX
        LOOP    OUTST1
OUTST9: RET

;  OUTNUM: print AX as a signed decimal number
OUTNUM: OR      AX, AX
        JNS     OUTN1
        PUSH    AX
        MOV     AL, '-'
        CALL    OUTCH
        POP     AX
        NEG     AX
OUTN1:  XOR     CX, CX
        MOV     BX, 10
OUTN2:  XOR     DX, DX
        DIV     BX
        PUSH    DX
        INC     CX
        OR      AX, AX
        JNZ     OUTN2
OUTN3:  POP     AX
        ADD     AL, '0'
        PUSH    CX
        CALL    OUTCH
        POP     CX
        LOOP    OUTN3
        RET

;  OUTHEX: print AX as 4 hex digits
OUTHEX: MOV     CX, 4
OUTH1:  PUSH    CX
        MOV     CL, 4
        ROL     AX, CL
        PUSH    AX
        AND     AL, 0FH
        ADD     AL, '0'
        CMP     AL, '9'
        JBE     OUTH2
        ADD     AL, 7
OUTH2:  CALL    OUTCH
        POP     AX
        POP     CX
        LOOP    OUTH1
        RET

;  FATAL: AX = error code.  Print it, wait for a key, exit.
;  FATALC: the screen can't be set up, so nothing can be shown: leave
;  through ErrorExit, and the Executive reports the code AX.
FATALC: PUSH    AX
        %CALLF(0334H,0FFEFH)
        JMP     CEXIT
FATAL:  PUSH    AX
        MOV     OUTMODE, 0
        MOV     AL, 13
        CALL    OUTCH
        MOV     SI, OFFSET ERRMSG
        MOV     CX, ERRMSGL
        CALL    OUTSTR
        POP     AX
        CALL    OUTNUM
        MOV     AL, '.'
        CALL    OUTCH
        MOV     AL, 13
        CALL    OUTCH
        CALL    SHOWLINE
        MOV     SI, OFFSET PRESSMSG
        MOV     CX, PRESSMSGL
        CALL    OUTSTR
        CALL    SHOWLINE
        CALL    SHOWCUR
        CALL    GETKEY
        JMP     CEXIT

; ======================================================================
;  Story memory
; ======================================================================

;  ADDRSEG: AX = byte address (0-FFFF) -> ES:BX
ADDRSEG:
        MOV     BX, AX
        AND     BX, 7FFFH
        SHL     AX, 1
        MOV     AX, CHSEG
        JNC     ADDRS1
        MOV     AX, CHSEG+2
ADDRS1: MOV     ES, AX
        RET

;  RDB: AL = byte at address AX (AH = 0)
RDB:    CALL    ADDRSEG
        MOV     AL, ES:[BX]
        XOR     AH, AH
        RET

;  RDW: AX = word at address AX
RDW:    CALL    ADDRSEG
        MOV     AH, ES:[BX]
        MOV     AL, ES:[BX+1]
        RET

;  WRB: byte DL to address AX
WRB:    CALL    ADDRSEG
        MOV     ES:[BX], DL
        RET

;  WRW: word DX to address AX
WRW:    CALL    ADDRSEG
        MOV     ES:[BX], DH
        MOV     ES:[BX+1], DL
        RET

;  FETCHB: AX = next byte at the PC
FETCHB: MOV     BX, PCCH
        SHL     BX, 1
        MOV     ES, CHSEG[BX]
        MOV     BX, PCOFF
        MOV     AL, ES:[BX]
        XOR     AH, AH
        INC     BX
        TEST    BX, 8000H
        JNZ     FETCB1
        MOV     PCOFF, BX
        RET
FETCB1: AND     BX, 7FFFH
        MOV     PCOFF, BX
        INC     PCCH
        RET

;  FETCHW: AX = next word at the PC
FETCHW: CALL    FETCHB
        PUSH    AX
        CALL    FETCHB
        POP     DX
        MOV     AH, DL
        RET

;  SETPCB: PC = byte address AX (0-FFFF)
SETPCB: MOV     BX, AX
        AND     BX, 7FFFH
        MOV     PCOFF, BX
        ROL     AX, 1
        AND     AX, 1
        MOV     PCCH, AX
        RET

;  SETPCP: PC = packed address AX (byte address 2*AX)
SETPCP: MOV     BX, AX
        SHL     BX, 1
        AND     BX, 7FFFH
        MOV     PCOFF, BX
        MOV     CL, 14
        SHR     AX, CL
        MOV     PCCH, AX
        RET

;  PCADD: PC = PC + AX (signed)
PCADD:  CWD                             ; DX:AX = the offset, sign extended
        MOV     BX, PCCH
        MOV     CX, BX
        SHR     CX, 1                   ; CX:BX = linear PC
        AND     BX, 1
        ROR     BX, 1
        OR      BX, PCOFF
        ADD     BX, AX
        ADC     CX, DX
        MOV     AX, BX
        AND     AX, 7FFFH
        MOV     PCOFF, AX
        SHL     BX, 1                   ; CF = bit 15
        RCL     CX, 1
        MOV     PCCH, CX
        RET

;  DPTR: the text pointer used by the Z-string decoder: DCH (chunk),
;  DOFF (offset).  SETDPB: from byte address AX.  SETDPP: packed AX.
SETDPB: MOV     BX, AX
        AND     BX, 7FFFH
        MOV     DOFF, BX
        ROL     AX, 1
        AND     AX, 1
        MOV     DCH, AX
        RET

SETDPP: MOV     BX, AX
        SHL     BX, 1
        AND     BX, 7FFFH
        MOV     DOFF, BX
        MOV     CL, 14
        SHR     AX, CL
        MOV     DCH, AX
        RET

;  DFETCHW: AX = word at the text pointer, which moves on
DFETCHW:
        MOV     BX, DCH
        CMP     BX, NCHUNKS
        JB      DFW1
        MOV     AX, 8000H               ; past the story: end the string
        RET
DFW1:   SHL     BX, 1
        MOV     ES, CHSEG[BX]
        MOV     BX, DOFF
        MOV     AH, ES:[BX]
        MOV     AL, ES:[BX+1]
        ADD     BX, 2
        TEST    BX, 8000H
        JNZ     DFW2
        MOV     DOFF, BX
        RET
DFW2:   AND     BX, 7FFFH
        MOV     DOFF, BX
        INC     DCH
        RET

; ======================================================================
;  Loading the story
; ======================================================================

;  GETPARAM: STORYNM / STORYLEN = the first subparameter of parameter 1,
;  the first field of the command form; STORYLEN = 0 if there is none.
;  Parameter 0 is the command name.  The Executive leaves the parameters in
;  the Variable-Length Parameter Block, which the ASCB points to (offset 2):
;    0  sVarParams       2  ibFirstFree
;    4  cParams, the number of fields (parameter 0 isn't counted)
;    6  for parameters 0 to cParams, the (offset, length) in the VLPB of
;       its subparameters, each of which is a length byte and its characters
GETPARAM:
        PUSH    SI
        PUSH    DI
        PUSH    ES
        MOV     STORYLEN, 0
        CALL    CGETASCB
        OR      AX, AX
        JNZ     GETP9
        LES     BX, DWORD PTR MEMPTR
        LES     BX, DWORD PTR ES:[BX+2]
        MOV     AX, ES
        OR      AX, BX
        JZ      GETP9                   ; no VLPB
        CMP     WORD PTR ES:[BX+4], 1
        JB      GETP9                   ; no parameter 1
        CMP     WORD PTR ES:[BX+12], 0
        JE      GETP9                   ; parameter 1 is empty
        MOV     SI, ES:[BX+10]
        ADD     SI, BX
        MOV     CL, ES:[SI]
        XOR     CH, CH
        CMP     CX, 78                  ; the longest file spec
        JBE     GETP1
        MOV     CX, 78
GETP1:  INC     SI
        MOV     STORYLEN, CX
        MOV     DI, OFFSET STORYNM
        PUSH    DS
        PUSH    ES
        POP     DS
        PUSH    CS
        POP     ES
        REP     MOVSB
        POP     DS
GETP9:  POP     ES
        POP     DI
        POP     SI
        RET

;  MKSAVENM: SAVENM / SAVELEN = the story's file name without its
;  directory and extension, then '.sav'.  Save files go in the current path.
MKSAVENM:
        PUSH    SI
        PUSH    DI
        PUSH    ES
        PUSH    DS
        POP     ES
        MOV     SI, OFFSET STORYNM
        MOV     CX, STORYLEN
        MOV     BX, SI                  ; where the file name starts
        XOR     DX, DX                  ; where its last '.' is (0: none)
MKS1:   JCXZ    MKS3
        LODSB
        DEC     CX
        CMP     AL, ']'
        JE      MKS2
        CMP     AL, '>'
        JE      MKS2
        CMP     AL, '.'
        JNE     MKS1
        MOV     DX, SI
        DEC     DX
        JMP     MKS1
MKS2:   MOV     BX, SI
        XOR     DX, DX
        JMP     MKS1
MKS3:   OR      DX, DX
        JZ      MKS4
        MOV     SI, DX
MKS4:   MOV     CX, SI
        SUB     CX, BX
        CMP     CX, 46                  ; file names are up to 50 characters
        JBE     MKS5
        MOV     CX, 46
MKS5:   MOV     SI, BX
        MOV     DI, OFFSET SAVENM
        REP     MOVSB
        MOV     SI, OFFSET SAVEEXT
        MOV     CX, SAVEEXTL
        REP     MOVSB
        SUB     DI, OFFSET SAVENM
        MOV     SAVELEN, DI
        POP     ES
        POP     DI
        POP     SI
        RET

;  OUTSTORY: print the story's file name
OUTSTORY:
        MOV     SI, OFFSET STORYNM
        MOV     CX, STORYLEN
        JMP     OUTSTR

;  LOADSTORY: open the file named on the command form, or if none,
;  Zork1.dat in the current path, then [Sys]<Sys>Zork1.dat.  Read it.
LOADSTORY:
        CALL    GETPARAM
        CMP     STORYLEN, 0
        JNE     LOADN
        PUSH    DS
        POP     ES
        MOV     SI, OFFSET STORY1
        MOV     DI, OFFSET STORYNM
        MOV     CX, STORY1L
        MOV     STORYLEN, CX
        REP     MOVSB
        MOV     DX, OFFSET STORY1
        MOV     CX, STORY1L
        MOV     BX, MODERD
        CALL    COPEN
        OR      AX, AX
        JZ      LOADS1
        MOV     DX, OFFSET STORY2
        MOV     CX, STORY2L
        MOV     BX, MODERD
        CALL    COPEN
        OR      AX, AX
        JZ      LOADS1
        PUSH    AX
        MOV     SI, OFFSET NOSTORY
        MOV     CX, NOSTORYL
        CALL    OUTSTR
        POP     AX
        JMP     FATAL
LOADN:  MOV     DX, OFFSET STORYNM
        MOV     CX, STORYLEN
        MOV     BX, MODERD
        CALL    COPEN
        OR      AX, AX
        JZ      LOADS1
        PUSH    AX
        MOV     SI, OFFSET NOOPEN
        MOV     CX, NOOPENL
        CALL    OUTSTR
        CALL    OUTSTORY
        MOV     AL, '.'
        CALL    OUTCH
        POP     AX
        JMP     FATAL
LOADS1: CALL    MKSAVENM
        MOV     AX, FHANDLE
        MOV     SFHANDLE, AX
        ; chunk 0 first: it holds the header, which gives the length
        XOR     SI, SI                  ; chunk index * 2
        MOV     NCHUNKS, 1
LOADS2: MOV     AX, CHUNKAL
        CALL    CALLOC
        OR      AX, AX
        JZ      LOADS3
        PUSH    AX
        MOV     SI, OFFSET NOMEM
        MOV     CX, NOMEML
        CALL    OUTSTR
        POP     AX
        JMP     FATAL
LOADS3: ; normalise the pointer to segment:0
        MOV     AX, MEMPTR
        MOV     BX, MEMPTR+2
        ADD     AX, 15
        MOV     CL, 4
        SHR     AX, CL
        ADD     AX, BX
        MOV     CHSEG[SI], AX
        ; Read(fh, seg:0, CHUNKSZ, lfa = index * 32768)
        MOV     ES, AX
        XOR     BX, BX
        MOV     CX, CHUNKSZ
        MOV     AX, SI
        SHR     AX, 1                   ; chunk index
        MOV     DX, AX
        SHR     DX, 1                   ; high word = index / 2
        AND     AX, 1
        MOV     CL, 15
        SHL     AX, CL                  ; low word = (index mod 2) * 32768
        MOV     CX, CHUNKSZ
        CALL    CREAD
        CMP     IOCOUNT, 0
        JNE     LOADS4
        OR      AX, AX
        JNZ     LOADSE
        MOV     AX, 1
LOADSE: JMP     FATAL
LOADS4: OR      SI, SI
        JNZ     LOADS5
        ; chunk 0: check the header and work out the number of chunks
        MOV     ES, CHSEG
        XOR     BX, BX
        CMP     BYTE PTR ES:[BX], 3
        JE      LOADS6
        CALL    OUTSTORY
        MOV     SI, OFFSET BADVER
        MOV     CX, BADVERL
        CALL    OUTSTR
        MOV     AX, 2
        JMP     FATAL
LOADS6: MOV     AH, ES:[BX+1AH]
        MOV     AL, ES:[BX+1BH]         ; length / 2
        MOV     DX, AX
        MOV     CL, 14                  ; chunks = ceil(len*2 / 32768) = ceil(len / 16384)
        SHR     DX, CL
        TEST    AX, 3FFFH
        JZ      LOADS7
        INC     DX
LOADS7: OR      DX, DX
        JNZ     LOADS8
        INC     DX
LOADS8: CMP     DX, MAXCHK
        JBE     LOADS9
        MOV     DX, MAXCHK
LOADS9: MOV     NCHUNKS, DX
LOADS5: ADD     SI, 2
        MOV     AX, SI
        SHR     AX, 1
        CMP     AX, NCHUNKS
        JAE     LOADSX
        JMP     LOADS2
LOADSX: RET

; ======================================================================
;  Start or restart the game
; ======================================================================
ZRESTART:
        ; read dynamic memory back from the file (first time: already there)
        CMP     STARTED, 0
        JE      ZRST1
        MOV     AX, SFHANDLE
        MOV     FHANDLE, AX
        MOV     ES, CHSEG
        XOR     BX, BX
        MOV     AH, ES:[BX+0EH]
        MOV     AL, ES:[BX+0FH]
        ADD     AX, 511
        AND     AX, 0FE00H
        MOV     CX, AX
        XOR     BX, BX
        XOR     AX, AX
        XOR     DX, DX
        CALL    CREAD
ZRST1:  MOV     STARTED, 1
        MOV     ES, CHSEG
        XOR     BX, BX
        ; flags 1: status line available, no split screen, fixed pitch
        AND     BYTE PTR ES:[BX+1], 8FH
        MOV     AH, ES:[BX+0AH]
        MOV     AL, ES:[BX+0BH]
        MOV     OBJTAB, AX
        MOV     AH, ES:[BX+0CH]
        MOV     AL, ES:[BX+0DH]
        MOV     GLOBALS, AX
        MOV     AH, ES:[BX+08H]
        MOV     AL, ES:[BX+09H]
        MOV     DICT, AX
        MOV     AH, ES:[BX+18H]
        MOV     AL, ES:[BX+19H]
        MOV     ABBREV, AX
        MOV     AH, ES:[BX+0EH]
        MOV     AL, ES:[BX+0FH]
        MOV     DYNSIZE, AX
        MOV     AH, ES:[BX+02H]
        MOV     AL, ES:[BX+03H]
        MOV     RELEASE, AX
        ; stack: an empty frame for the main routine
        MOV     ZSP, 10
        MOV     ZFP, 10
        MOV     AH, ES:[BX+06H]
        MOV     AL, ES:[BX+07H]
        CALL    SETPCB
        MOV     OUTMODE, 0
        RET

; ======================================================================
;  Random numbers: a 32-bit linear congruential generator
; ======================================================================
RNDSEED:
        CALL    CGETDT
        MOV     AX, MEMPTR
        MOV     DX, MEMPTR+2
        XOR     AX, 5A5AH
        MOV     RNDLO, AX
        MOV     RNDHI, DX
        RET

;  RNDNEXT: AX = next 15-bit random value
RNDNEXT:
        ; seed = seed * 015A4E35h + 1
        MOV     AX, RNDLO
        MOV     BX, 4E35H
        MUL     BX                      ; DX:AX = lo * 4E35
        MOV     CX, AX
        PUSH    DX
        MOV     AX, RNDHI
        MUL     BX                      ; hi * 4E35 (low word)
        POP     DX
        ADD     DX, AX
        MOV     AX, RNDLO
        MOV     BX, 015AH
        PUSH    DX
        MUL     BX
        POP     DX
        ADD     DX, AX
        ADD     CX, 1
        ADC     DX, 0
        MOV     RNDLO, CX
        MOV     RNDHI, DX
        MOV     AX, DX
        AND     AX, 7FFFH
        RET

; ======================================================================
;  Main loop: decode and run one instruction at a time
; ======================================================================
MAINLOOP:
        MOV     SP, OFFSET STKTOP
        CALL    STEP
        JMP     MAINLOOP

STEP:   CALL    FETCHB
        MOV     OPCODE, AL
        MOV     NOPS, 0
        CMP     AL, 80H
        JAE     STEP1
        ; long form: 2OP, operand types in bits 6 and 5
        MOV     CL, AL
        MOV     DL, 1                   ; small constant
        TEST    CL, 40H
        JZ      STEPL1
        MOV     DL, 2                   ; variable
STEPL1: MOV     AL, DL
        CALL    GETOP
        MOV     CL, OPCODE
        MOV     DL, 1
        TEST    CL, 20H
        JZ      STEPL2
        MOV     DL, 2
STEPL2: MOV     AL, DL
        CALL    GETOP
        MOV     BL, OPCODE
        AND     BX, 1FH
        SHL     BX, 1
        JMP     T2OP[BX]
STEP1:  CMP     AL, 0C0H
        JAE     STEPV
        ; short form
        MOV     CL, 4
        SHR     AL, CL
        AND     AL, 3
        CMP     AL, 3
        JE      STEP0
        CALL    GETOP
        MOV     BL, OPCODE
        AND     BX, 0FH
        SHL     BX, 1
        JMP     T1OP[BX]
STEP0:  MOV     BL, OPCODE
        AND     BX, 0FH
        SHL     BX, 1
        JMP     T0OP[BX]
STEPV:  ; variable form: a byte of 4 operand types
        CALL    FETCHB
        MOV     CH, AL
        MOV     CL, 4
STEPV1: MOV     AL, CH
        ROL     AL, 1
        ROL     AL, 1
        MOV     CH, AL
        AND     AL, 3
        CMP     AL, 3
        JE      STEPV2
        PUSH    CX
        CALL    GETOP
        POP     CX
        DEC     CL
        JNZ     STEPV1
STEPV2: MOV     BL, OPCODE
        AND     BX, 1FH
        SHL     BX, 1
        TEST    OPCODE, 20H
        JNZ     STEPV3
        JMP     T2OP[BX]
STEPV3: JMP     TVAR[BX]

;  GETOP: read one operand of type AL (0 large constant, 1 small constant,
;  2 variable) and append it to OPS
GETOP:  OR      AL, AL
        JNZ     GETOP1
        CALL    FETCHW
        JMP     GETOP9
GETOP1: CMP     AL, 1
        JNE     GETOP2
        CALL    FETCHB
        JMP     GETOP9
GETOP2: CALL    FETCHB
        CALL    RDVAR
GETOP9: MOV     BX, NOPS
        SHL     BX, 1
        MOV     OPS[BX], AX
        INC     NOPS
        RET

; ======================================================================
;  Variables
; ======================================================================

;  RDVAR: AX = value of variable AL (0 pops the stack)
RDVAR:  XOR     AH, AH
        OR      AL, AL
        JNZ     RDV1
        JMP     ZPOP
RDV1:   CMP     AL, 16
        JAE     RDV2
        ; local
        DEC     AX
        SHL     AX, 1
        ADD     AX, ZFP
        MOV     BX, AX
        MOV     AX, ZSTK[BX]
        RET
RDV2:   SUB     AX, 16
        SHL     AX, 1
        ADD     AX, GLOBALS
        JMP     RDW

;  WRVAR: variable AL = DX (0 pushes)
WRVAR:  XOR     AH, AH
        OR      AL, AL
        JNZ     WRV1
        MOV     AX, DX
        JMP     ZPUSH
WRV1:   CMP     AL, 16
        JAE     WRV2
        DEC     AX
        SHL     AX, 1
        ADD     AX, ZFP
        MOV     BX, AX
        MOV     ZSTK[BX], DX
        RET
WRV2:   SUB     AX, 16
        SHL     AX, 1
        ADD     AX, GLOBALS
        JMP     WRW

;  RDVARI / WRVARI: the same, but variable 0 is the top of the stack in
;  place (for the opcodes that name a variable as an operand)
RDVARI: OR      AL, AL
        JNZ     RDVAR
        MOV     BX, ZSP
        MOV     AX, ZSTK[BX-2]
        RET
WRVARI: OR      AL, AL
        JNZ     WRVAR
        MOV     BX, ZSP
        MOV     ZSTK[BX-2], DX
        RET

;  ZPUSH: push AX on the Z-stack
ZPUSH:  MOV     BX, ZSP
        CMP     BX, ZSTKSZ-2
        JB      ZPUSH1
        MOV     AX, 3
        JMP     FATAL
ZPUSH1: MOV     ZSTK[BX], AX
        ADD     BX, 2
        MOV     ZSP, BX
        RET

;  ZPOP: AX = popped from the Z-stack
ZPOP:   MOV     BX, ZSP
        CMP     BX, ZFP
        JA      ZPOP1
        MOV     AX, 4                   ; stack underflow
        JMP     FATAL
ZPOP1:  SUB     BX, 2
        MOV     ZSP, BX
        MOV     AX, ZSTK[BX]
        RET

;  STORE: fetch the store variable byte and write AX to it
STORE:  PUSH    AX
        CALL    FETCHB
        POP     DX
        JMP     WRVAR

;  BRANCH: AL = condition (0 false).  Fetch the branch bytes and branch.
BRANCH: MOV     COND, AL
        CALL    FETCHB
        MOV     CL, AL                  ; first branch byte
        TEST    AL, 40H
        JZ      BRL
        AND     AX, 3FH                 ; short: 0-63
        JMP     BR1
BRL:    PUSH    CX
        AND     AL, 3FH
        PUSH    AX
        CALL    FETCHB
        POP     DX
        MOV     AH, DL
        TEST    AH, 20H                 ; sign of the 14-bit offset
        JZ      BRL1
        OR      AH, 0C0H
BRL1:   POP     CX
BR1:    ; AX = offset, CL bit 7 = branch on true
        MOV     DL, COND
        OR      DL, DL
        JZ      BR2
        MOV     DL, 80H
BR2:    AND     CL, 80H
        CMP     CL, DL
        JNE     BR9                     ; condition does not match: no branch
        CMP     AX, 1
        JA      BR3
        JMP     ZRET                    ; 0: return false, 1: return true
BR3:    SUB     AX, 2
        JMP     PCADD
BR9:    RET

;  ZRET: return AX from the current routine
ZRET:   MOV     BX, ZFP
        SUB     BX, 10
        MOV     ZSP, BX
        MOV     CX, ZSTK[BX]
        MOV     PCOFF, CX
        MOV     CX, ZSTK[BX+2]
        MOV     PCCH, CX
        MOV     CX, ZSTK[BX+6]
        MOV     ZFP, CX
        MOV     CX, ZSTK[BX+4]          ; store variable, or 0FFFFh for none
        CMP     CX, 0FFFFH
        JE      ZRET9
        MOV     DX, AX
        MOV     AL, CL
        JMP     WRVAR
ZRET9:  RET

; ======================================================================
;  Objects
; ======================================================================

;  OBJADDR: AX = object number -> AX = address of its entry
OBJADDR:
        DEC     AX
        MOV     BX, 9
        MUL     BX
        ADD     AX, OBJTAB
        ADD     AX, 62
        RET

;  OBJGET: AX = object, CX = field offset (4 parent, 5 sibling, 6 child)
;  -> AX = the field
OBJGET: OR      AX, AX
        JZ      OBJG9
        CALL    OBJADDR
        ADD     AX, CX
        JMP     RDB
OBJG9:  RET

;  OBJSET: AX = object, CX = field offset, DL = value
OBJSET: OR      AX, AX
        JZ      OBJS9
        PUSH    DX
        CALL    OBJADDR
        ADD     AX, CX
        POP     DX
        JMP     WRB
OBJS9:  RET

;  ATTRADDR: AX = object, DX = attribute -> AX = address of the byte,
;  DL = bit mask
ATTRADDR:
        PUSH    DX
        CALL    OBJADDR
        POP     DX
        MOV     CX, DX
        SHR     DX, 1
        SHR     DX, 1
        SHR     DX, 1
        ADD     AX, DX
        AND     CL, 7
        MOV     DL, 80H
        SHR     DL, CL
        RET

;  UNLINK: take object AX out of its parent's child list
UNLINK: PUSH    SI
        PUSH    DI
        MOV     SI, AX                  ; object
        MOV     CX, 4
        CALL    OBJGET
        OR      AX, AX
        JZ      UNL9                    ; no parent
        MOV     DI, AX                  ; parent
        MOV     CX, 6
        CALL    OBJGET
        CMP     AX, SI
        JNE     UNL2
        ; first child: parent's child = object's sibling
        MOV     AX, SI
        MOV     CX, 5
        CALL    OBJGET
        MOV     DX, AX
        MOV     AX, DI
        MOV     CX, 6
        CALL    OBJSET
        JMP     UNL8
UNL2:   ; AX = a child; find the one whose sibling is the object
        OR      AX, AX
        JZ      UNL8                    ; not found (corrupt tree): just detach
        MOV     DI, AX
        MOV     CX, 5
        CALL    OBJGET
        CMP     AX, SI
        JNE     UNL2
        MOV     AX, SI
        MOV     CX, 5
        CALL    OBJGET
        MOV     DX, AX
        MOV     AX, DI
        MOV     CX, 5
        CALL    OBJSET
UNL8:   MOV     AX, SI
        MOV     CX, 4
        XOR     DX, DX
        CALL    OBJSET
        MOV     AX, SI
        MOV     CX, 5
        XOR     DX, DX
        CALL    OBJSET
UNL9:   POP     DI
        POP     SI
        RET

;  PROPTAB: AX = object -> AX = address of its property table
PROPTAB:
        CALL    OBJADDR
        ADD     AX, 7
        JMP     RDW

;  PROPFIRST: AX = object -> AX = address of its first property's size byte
PROPFIRST:
        CALL    PROPTAB
        PUSH    AX
        CALL    RDB
        SHL     AX, 1
        POP     DX
        ADD     AX, DX
        INC     AX
        RET

;  PROPFIND: AX = object, DX = property -> AX = address of the size
;  byte, or 0; CX = length of the data
PROPFIND:
        PUSH    SI
        PUSH    DI
        MOV     DI, DX
        CALL    PROPFIRST
        MOV     SI, AX
PROPF1: MOV     AX, SI
        CALL    RDB
        OR      AL, AL
        JZ      PROPF8
        MOV     CX, AX
        AND     AX, 1FH
        CMP     AX, DI
        JE      PROPF9
        JB      PROPF8                  ; properties are in descending order
        MOV     BX, CX
        MOV     CL, 5
        SHR     BX, CL
        ADD     SI, BX
        ADD     SI, 2
        JMP     PROPF1
PROPF8: XOR     AX, AX
        XOR     CX, CX
        POP     DI
        POP     SI
        RET
PROPF9: MOV     AX, SI
        PUSH    AX
        MOV     AX, CX
        MOV     CL, 5
        SHR     AX, CL
        INC     AX
        MOV     CX, AX
        POP     AX
        POP     DI
        POP     SI
        RET

; ======================================================================
;  Z-string decoding.  DECODE prints the string at the text pointer
;  (DCH, DOFF) and leaves the pointer after it.
; ======================================================================
DECODE: MOV     ZSHIFT, 0
        MOV     ZESC, 0
        MOV     ZABBR, 0
DEC1:   CALL    DFETCHW
        PUSH    AX
        MOV     CL, 10
        SHR     AX, CL
        AND     AL, 1FH
        CALL    ZCHAR
        POP     AX
        PUSH    AX
        MOV     CL, 5
        SHR     AX, CL
        AND     AL, 1FH
        CALL    ZCHAR
        POP     AX
        PUSH    AX
        AND     AL, 1FH
        CALL    ZCHAR
        POP     AX
        TEST    AX, 8000H
        JZ      DEC1
        RET

;  ZCHAR: handle one 5-bit z-character AL
ZCHAR:  XOR     AH, AH
        CMP     ZESC, 0
        JE      ZCH1
        CMP     ZESC, 1
        JNE     ZCHE2
        MOV     ZESCHI, AL
        MOV     ZESC, 2
        RET
ZCHE2:  MOV     ZESC, 0
        MOV     CL, 5
        MOV     DL, ZESCHI
        SHL     DL, CL
        OR      AL, DL
        JMP     OUTCH
ZCH1:   CMP     ZABBR, 0
        JE      ZCH2
        ; abbreviation entry 32 * (ZABBR - 1) + AL
        MOV     BL, ZABBR
        MOV     ZABBR, 0
        XOR     BH, BH
        DEC     BX
        MOV     CL, 5
        SHL     BX, CL
        ADD     BX, AX
        SHL     BX, 1
        MOV     AX, ABBREV
        ADD     AX, BX
        CALL    RDW                     ; word address of the string
        ; save the decoder state and print the abbreviation
        PUSH    WORD PTR DCH
        PUSH    WORD PTR DOFF
        CALL    SETDPP                  ; a word address is a packed address
        CALL    DECODE
        POP     WORD PTR DOFF
        POP     WORD PTR DCH
        MOV     ZSHIFT, 0
        MOV     ZESC, 0
        MOV     ZABBR, 0
        RET
ZCH2:   OR      AL, AL
        JNZ     ZCH3
        MOV     ZSHIFT, 0
        MOV     AL, ' '
        JMP     OUTCH
ZCH3:   CMP     AL, 4
        JAE     ZCH4
        MOV     ZABBR, AL
        RET
ZCH4:   JNE     ZCH5
        MOV     ZSHIFT, 1
        RET
ZCH5:   CMP     AL, 5
        JNE     ZCH6
        MOV     ZSHIFT, 2
        RET
ZCH6:   ; 6-31: a character from the current alphabet
        MOV     DL, ZSHIFT
        MOV     ZSHIFT, 0
        CMP     DL, 2
        JNE     ZCH7
        CMP     AL, 6
        JNE     ZCH6A
        MOV     ZESC, 1                 ; 10-bit ZSCII follows
        RET
ZCH6A:  CMP     AL, 7
        JNE     ZCH7
        MOV     AL, 13
        JMP     OUTCH
ZCH7:   SUB     AL, 6
        MOV     BL, DL
        XOR     BH, BH
        MOV     CX, 26
        PUSH    AX
        MOV     AX, BX
        MUL     CX
        POP     BX
        ADD     BX, AX
        MOV     AL, ALPHA[BX]
        JMP     OUTCH

; ======================================================================
;  Opcode handlers.  OPS holds the operands, NOPS how many.
; ======================================================================

OPBAD:  MOV     AL, OPCODE
        XOR     AH, AH
        ADD     AX, 1000                ; error 1000 + opcode: unknown opcode
        JMP     FATAL

OPNOP:  RET

; ---- 2OP
OPJE:   MOV     AX, OPS
        MOV     CX, NOPS
        DEC     CX
        MOV     BX, 2
OPJE1:  JCXZ    OPJE8
        CMP     AX, OPS[BX]
        JE      OPJE9
        ADD     BX, 2
        DEC     CX
        JMP     OPJE1
OPJE8:  XOR     AL, AL
        JMP     BRANCH
OPJE9:  MOV     AL, 1
        JMP     BRANCH

OPJL:   MOV     AX, OPS
        CMP     AX, OPS+2
        MOV     AL, 0
        JGE     OPJL1
        MOV     AL, 1
OPJL1:  JMP     BRANCH

OPJG:   MOV     AX, OPS
        CMP     AX, OPS+2
        MOV     AL, 0
        JLE     OPJG1
        MOV     AL, 1
OPJG1:  JMP     BRANCH

OPDECCHK:
        MOV     AL, BYTE PTR OPS
        CALL    RDVARI
        DEC     AX
        PUSH    AX
        MOV     DX, AX
        MOV     AL, BYTE PTR OPS
        CALL    WRVARI
        POP     AX
        CMP     AX, OPS+2
        MOV     AL, 0
        JGE     OPDC1
        MOV     AL, 1
OPDC1:  JMP     BRANCH

OPINCCHK:
        MOV     AL, BYTE PTR OPS
        CALL    RDVARI
        INC     AX
        PUSH    AX
        MOV     DX, AX
        MOV     AL, BYTE PTR OPS
        CALL    WRVARI
        POP     AX
        CMP     AX, OPS+2
        MOV     AL, 0
        JLE     OPIC1
        MOV     AL, 1
OPIC1:  JMP     BRANCH

OPJIN:  MOV     AX, OPS
        MOV     CX, 4
        CALL    OBJGET
        CMP     AX, OPS+2
        MOV     AL, 0
        JNE     OPJIN1
        MOV     AL, 1
OPJIN1: JMP     BRANCH

OPTEST: MOV     AX, OPS
        MOV     DX, OPS+2
        AND     AX, DX
        CMP     AX, DX
        MOV     AL, 0
        JNE     OPTST1
        MOV     AL, 1
OPTST1: JMP     BRANCH

OPOR:   MOV     AX, OPS
        OR      AX, OPS+2
        JMP     STORE

OPAND:  MOV     AX, OPS
        AND     AX, OPS+2
        JMP     STORE

OPTATTR:
        MOV     AX, OPS
        MOV     DX, OPS+2
        CALL    ATTRADDR
        PUSH    DX
        CALL    RDB
        POP     DX
        AND     AL, DL
        JMP     BRANCH

OPSATTR:
        MOV     AX, OPS
        MOV     DX, OPS+2
        CALL    ATTRADDR
        PUSH    AX
        PUSH    DX
        CALL    RDB
        POP     DX
        OR      DL, AL
        POP     AX
        JMP     WRB

OPCATTR:
        MOV     AX, OPS
        MOV     DX, OPS+2
        CALL    ATTRADDR
        PUSH    AX
        PUSH    DX
        CALL    RDB
        POP     DX
        NOT     DL
        AND     DL, AL
        POP     AX
        JMP     WRB

OPSTORE:
        MOV     AL, BYTE PTR OPS
        MOV     DX, OPS+2
        JMP     WRVARI

OPINSERT:
        MOV     AX, OPS
        OR      AX, AX
        JZ      OPINS9
        CALL    UNLINK
        ; object's sibling = dest's first child
        MOV     AX, OPS+2
        MOV     CX, 6
        CALL    OBJGET
        MOV     DX, AX
        MOV     AX, OPS
        MOV     CX, 5
        CALL    OBJSET
        ; dest's child = object
        MOV     AX, OPS+2
        MOV     DX, OPS
        MOV     CX, 6
        CALL    OBJSET
        ; object's parent = dest
        MOV     AX, OPS
        MOV     DX, OPS+2
        MOV     CX, 4
        CALL    OBJSET
OPINS9: RET

OPLOADW:
        MOV     AX, OPS+2
        SHL     AX, 1
        ADD     AX, OPS
        CALL    RDW
        JMP     STORE

OPLOADB:
        MOV     AX, OPS+2
        ADD     AX, OPS
        CALL    RDB
        JMP     STORE

OPGETPROP:
        MOV     AX, OPS
        MOV     DX, OPS+2
        CALL    PROPFIND
        OR      AX, AX
        JZ      OPGP2
        INC     AX
        CMP     CX, 1
        JNE     OPGP1
        CALL    RDB
        JMP     STORE
OPGP1:  CALL    RDW
        JMP     STORE
OPGP2:  ; the default value
        MOV     AX, OPS+2
        DEC     AX
        SHL     AX, 1
        ADD     AX, OBJTAB
        CALL    RDW
        JMP     STORE

OPGETPA:
        MOV     AX, OPS
        MOV     DX, OPS+2
        CALL    PROPFIND
        OR      AX, AX
        JZ      OPGPA1
        INC     AX
OPGPA1: JMP     STORE

OPGETNP:
        MOV     AX, OPS
        MOV     DX, OPS+2
        OR      DX, DX
        JNZ     OPGNP1
        CALL    PROPFIRST
        JMP     OPGNP2
OPGNP1: CALL    PROPFIND
        OR      AX, AX
        JZ      OPGNP3
        ADD     AX, CX
        INC     AX
OPGNP2: CALL    RDB
        AND     AX, 1FH
OPGNP3: JMP     STORE

OPADD:  MOV     AX, OPS
        ADD     AX, OPS+2
        JMP     STORE

OPSUB:  MOV     AX, OPS
        SUB     AX, OPS+2
        JMP     STORE

OPMUL:  MOV     AX, OPS
        IMUL    WORD PTR OPS+2
        JMP     STORE

OPDIV:  MOV     CX, OPS+2
        OR      CX, CX
        JNZ     OPDIV1
        MOV     AX, 5                   ; division by zero
        JMP     FATAL
OPDIV1: MOV     AX, OPS
        CWD
        IDIV    CX
        JMP     STORE

OPMOD:  MOV     CX, OPS+2
        OR      CX, CX
        JNZ     OPMOD1
        MOV     AX, 5
        JMP     FATAL
OPMOD1: MOV     AX, OPS
        CWD
        IDIV    CX
        MOV     AX, DX
        JMP     STORE

; ---- 1OP
OPJZ:   MOV     AX, OPS
        OR      AX, AX
        MOV     AL, 0
        JNZ     OPJZ1
        MOV     AL, 1
OPJZ1:  JMP     BRANCH

OPGETSIB:
        MOV     CX, 5
        JMP     OPGETREL
OPGETCHILD:
        MOV     CX, 6
OPGETREL:
        MOV     AX, OPS
        CALL    OBJGET
        PUSH    AX
        CALL    STORE
        POP     AX
        JMP     BRANCH

OPGETPAR:
        MOV     AX, OPS
        MOV     CX, 4
        CALL    OBJGET
        JMP     STORE

OPGETPLEN:
        MOV     AX, OPS
        OR      AX, AX
        JZ      OPGPL1
        DEC     AX
        CALL    RDB
        MOV     CL, 5
        SHR     AX, CL
        INC     AX
OPGPL1: JMP     STORE

OPINC:  MOV     AL, BYTE PTR OPS
        CALL    RDVARI
        INC     AX
        MOV     DX, AX
        MOV     AL, BYTE PTR OPS
        JMP     WRVARI

OPDEC:  MOV     AL, BYTE PTR OPS
        CALL    RDVARI
        DEC     AX
        MOV     DX, AX
        MOV     AL, BYTE PTR OPS
        JMP     WRVARI

OPPRADDR:
        MOV     AX, OPS
        CALL    SETDPB
        JMP     DECODE

OPREMOVE:
        MOV     AX, OPS
        OR      AX, AX
        JZ      OPREM9
        CALL    UNLINK
OPREM9: RET

OPPROBJ:
        MOV     AX, OPS
PROBJ:  OR      AX, AX
        JZ      PROBJ9
        CALL    PROPTAB
        PUSH    AX
        CALL    RDB
        POP     DX
        OR      AX, AX
        JZ      PROBJ9                  ; no name
        MOV     AX, DX
        INC     AX
        CALL    SETDPB
        JMP     DECODE
PROBJ9: RET

OPRET:  MOV     AX, OPS
        JMP     ZRET

OPJUMP: MOV     AX, OPS
        SUB     AX, 2
        JMP     PCADD

OPPRPADDR:
        MOV     AX, OPS
        CALL    SETDPP
        JMP     DECODE

OPLOAD: MOV     AL, BYTE PTR OPS
        CALL    RDVARI
        JMP     STORE

OPNOT:  MOV     AX, OPS
        NOT     AX
        JMP     STORE

; ---- 0OP
OPRTRUE:
        MOV     AX, 1
        JMP     ZRET

OPRFALSE:
        XOR     AX, AX
        JMP     ZRET

OPPRINT:
        ; the string follows the opcode
        MOV     AX, PCCH
        MOV     DCH, AX
        MOV     AX, PCOFF
        MOV     DOFF, AX
        CALL    DECODE
        MOV     AX, DCH
        MOV     PCCH, AX
        MOV     AX, DOFF
        MOV     PCOFF, AX
        RET

OPPRRET:
        CALL    OPPRINT
        MOV     AL, 13
        CALL    OUTCH
        MOV     AX, 1
        JMP     ZRET

OPRESTART:
        MOV     AL, 13
        CALL    OUTCH
        CALL    ZRESTART
        RET

OPRETPOP:
        CALL    ZPOP
        JMP     ZRET

OPPOP:  JMP     ZPOP

OPQUIT: MOV     AL, 13
        CALL    OUTCH
        MOV     SI, OFFSET PRESSMSG
        MOV     CX, PRESSMSGL
        CALL    OUTSTR
        CALL    SHOWLINE
        CALL    SHOWCUR
        CALL    GETKEY
        JMP     CEXIT

OPNEWLINE:
        MOV     AL, 13
        JMP     OUTCH

OPSHOWST:
        JMP     STATUSLINE

OPVERIFY:
        MOV     AL, 1
        JMP     BRANCH

; ---- VAR
;  call routine arg1 .. arg3 -> store
OPCALL: MOV     AX, OPS
        OR      AX, AX
        JNZ     OPCALL1
        JMP     STORE                   ; calling address 0 returns false
OPCALL1:
        CALL    FETCHB                  ; the store variable
        MOV     DX, AX
        ; the frame: return PC, store variable, old frame pointer, arg count
        MOV     BX, ZSP
        CMP     BX, ZSTKSZ-48
        JB      OPCALL2
        MOV     AX, 3
        JMP     FATAL
OPCALL2:
        MOV     AX, PCOFF
        MOV     ZSTK[BX], AX
        MOV     AX, PCCH
        MOV     ZSTK[BX+2], AX
        MOV     ZSTK[BX+4], DX
        MOV     AX, ZFP
        MOV     ZSTK[BX+6], AX
        MOV     AX, NOPS
        DEC     AX
        MOV     ZSTK[BX+8], AX
        ADD     BX, 10
        MOV     ZFP, BX
        MOV     ZSP, BX
        MOV     AX, OPS
        CALL    SETPCP
        CALL    FETCHB                  ; number of locals
        MOV     CX, AX
        CMP     CX, 15
        JBE     OPCALL3
        MOV     AX, 6
        JMP     FATAL
OPCALL3:
        PUSH    SI
        MOV     SI, 2                   ; offset of the next argument in OPS
OPCALL4:
        JCXZ    OPCALL6
        PUSH    CX
        CALL    FETCHW                  ; initial value
        MOV     BX, NOPS
        SHL     BX, 1
        CMP     SI, BX
        JAE     OPCALL5
        MOV     AX, OPS[SI]
OPCALL5:
        ADD     SI, 2
        MOV     BX, ZSP
        MOV     ZSTK[BX], AX
        ADD     BX, 2
        MOV     ZSP, BX
        POP     CX
        DEC     CX
        JMP     OPCALL4
OPCALL6:
        POP     SI
        RET

OPSTOREW:
        MOV     AX, OPS+2
        SHL     AX, 1
        ADD     AX, OPS
        MOV     DX, OPS+4
        JMP     WRW

OPSTOREB:
        MOV     AX, OPS+2
        ADD     AX, OPS
        MOV     DX, OPS+4
        JMP     WRB

OPPUTPROP:
        MOV     AX, OPS
        MOV     DX, OPS+2
        CALL    PROPFIND
        OR      AX, AX
        JNZ     OPPP1
        MOV     AX, 7                   ; no such property
        JMP     FATAL
OPPP1:  INC     AX
        MOV     DX, OPS+4
        CMP     CX, 1
        JNE     OPPP2
        JMP     WRB
OPPP2:  JMP     WRW

OPPRCHAR:
        MOV     AL, BYTE PTR OPS
        JMP     OUTCH

OPPRNUM:
        MOV     AX, OPS
        JMP     OUTNUM

OPRANDOM:
        MOV     AX, OPS
        OR      AX, AX
        JG      OPRND2
        JZ      OPRND1
        ; negative: seed with -n
        NEG     AX
        MOV     RNDLO, AX
        MOV     RNDHI, 0
        XOR     AX, AX
        JMP     STORE
OPRND1: CALL    RNDSEED
        XOR     AX, AX
        JMP     STORE
OPRND2: CALL    RNDNEXT
        XOR     DX, DX
        DIV     WORD PTR OPS
        MOV     AX, DX
        INC     AX
        JMP     STORE

OPPUSH: MOV     AX, OPS
        JMP     ZPUSH

OPPULL: CALL    ZPOP
        MOV     DX, AX
        MOV     AL, BYTE PTR OPS
        JMP     WRVARI

; ======================================================================
;  Status line
; ======================================================================
STATUSLINE:
        PUSH    SI
        PUSH    DI
        PUSH    DS
        POP     ES
        MOV     DI, OFFSET STATBUF
        MOV     CX, COLS
        MOV     AL, ' '
        REP     STOSB
        MOV     OUTMODE, 1
        MOV     STATPOS, 1
        ; location: global 0
        MOV     AL, 16
        CALL    RDVAR
        CALL    PROBJ
        ; score and moves (a time game would show the time; Zork I isn't one)
        MOV     STATPOS, 55
        MOV     SI, OFFSET SCOREMSG
        MOV     CX, SCOREMSGL
        CALL    OUTSTR
        MOV     AL, 17
        CALL    RDVAR
        CALL    OUTNUM
        MOV     STATPOS, 68
        MOV     SI, OFFSET MOVESMSG
        MOV     CX, MOVESMSGL
        CALL    OUTSTR
        MOV     AL, 18
        CALL    RDVAR
        CALL    OUTNUM
        MOV     OUTMODE, 0
        ; draw it in reverse video
        XOR     AX, AX
        XOR     BX, BX
        XOR     CX, CX
        MOV     DX, OFFSET STATBUF
        MOV     DI, COLS
        CALL    CPUTCH
        XOR     AX, AX
        XOR     BX, BX
        XOR     CX, CX
        MOV     DX, 4                   ; reverse video
        MOV     DI, COLS
        CALL    CPUTAT
        POP     DI
        POP     SI
        RET

; ======================================================================
;  Input
; ======================================================================

;  READLINE: read a line into INBUF (lower case), at most CX characters,
;  echoing it at the end of the bottom line.  INLEN = its length.
READLINE:
        MOV     INMAX, CX
        MOV     INLEN, 0
        MOV     MORECNT, 0
        ; leave room on the line
        MOV     AX, COLS-1
        SUB     AX, LINELEN
        JA      RDL0
        CALL    SCRNL
        MOV     AX, COLS-1
RDL0:   CMP     INMAX, AX
        JBE     RDL1
        MOV     INMAX, AX
RDL1:   CALL    SHOWLINE
        CALL    SHOWCUR
        CALL    GETKEY
        CMP     AL, 0AH
        JE      RDLEND
        CMP     AL, 0DH
        JE      RDLEND
        CMP     AL, 1BH                 ; GO also ends the line
        JE      RDLEND
        CMP     AL, 08H
        JE      RDLBS
        CMP     AL, 7FH
        JE      RDLBS
        CMP     AL, ' '
        JB      RDL1
        CMP     AL, 7EH
        JA      RDL1
        MOV     BX, INLEN
        CMP     BX, INMAX
        JAE     RDLFULL
        MOV     DL, AL                  ; echo as typed, store in lower case
        CMP     AL, 'A'
        JB      RDL2
        CMP     AL, 'Z'
        JA      RDL2
        ADD     AL, 20H
RDL2:   MOV     INBUF[BX], AL
        INC     INLEN
        MOV     BX, LINELEN
        MOV     LINEBUF[BX], DL
        INC     LINELEN
        JMP     RDL1
RDLFULL:
        CALL    CBEEP
        JMP     RDL1
RDLBS:  CMP     INLEN, 0
        JE      RDL1
        DEC     INLEN
        DEC     LINELEN
        MOV     BX, LINELEN
        MOV     LINEBUF[BX], ' '
        JMP     RDL1
RDLEND: CALL    SCRNL
        MOV     MORECNT, 0
        RET

;  sread text parse
OPSREAD:
        CALL    STATUSLINE
        PUSH    SI
        PUSH    DI
        ; max letters = text[0] - 1
        MOV     AX, OPS
        CALL    RDB
        DEC     AX
        JNS     OPSR1
        XOR     AX, AX
OPSR1:  CMP     AX, INBUFSZ
        JBE     OPSR2
        MOV     AX, INBUFSZ
OPSR2:  MOV     CX, AX
        CALL    READLINE
        ; copy into the text buffer, from byte 1, ending with 0
        XOR     SI, SI
OPSR3:  CMP     SI, INLEN
        JAE     OPSR4
        MOV     DL, INBUF[SI]
        MOV     AX, OPS
        ADD     AX, SI
        INC     AX
        CALL    WRB
        INC     SI
        JMP     OPSR3
OPSR4:  MOV     AX, OPS
        ADD     AX, SI
        INC     AX
        XOR     DL, DL
        CALL    WRB
        POP     DI
        POP     SI
        JMP     TOKENISE

;  TOKENISE: split INBUF into words and look them up; fill the parse
;  buffer at OPS+2
TOKENISE:
        PUSH    SI
        PUSH    DI
        MOV     AX, OPS+2
        CALL    RDB
        MOV     PMAX, AX
        MOV     PCOUNT, 0
        ; the separators
        MOV     AX, DICT
        CALL    RDB
        MOV     NSEP, AX
        MOV     SI, DICT
        INC     SI
        XOR     DI, DI
TOK0:   CMP     DI, NSEP
        JAE     TOK0E
        CMP     DI, 16
        JAE     TOK0E
        MOV     AX, SI
        CALL    RDB
        MOV     SEPS[DI], AL
        INC     SI
        INC     DI
        JMP     TOK0
TOK0E:  MOV     SI, DICT
        INC     SI
        ADD     SI, NSEP
        MOV     AX, SI
        CALL    RDB
        MOV     DENTLEN, AX
        INC     SI
        MOV     AX, SI
        CALL    RDW
        MOV     DCOUNT, AX
        ADD     SI, 2
        MOV     DFIRST, SI
        ; walk the input
        XOR     SI, SI                  ; index into INBUF
TOK1:   CMP     SI, INLEN
        JB      TOK1A
        JMP     TOKEND
TOK1A:  MOV     AL, INBUF[SI]
        CMP     AL, ' '
        JNE     TOK2
        INC     SI
        JMP     TOK1
TOK2:   MOV     WSTART, SI
        CALL    ISSEP
        JNC     TOK3
        INC     SI                      ; a separator is a word by itself
        JMP     TOK5
TOK3:   ; up to a space, a separator or the end
        INC     SI
        CMP     SI, INLEN
        JAE     TOK5
        MOV     AL, INBUF[SI]
        CMP     AL, ' '
        JE      TOK5
        CALL    ISSEP
        JNC     TOK3
TOK5:   MOV     AX, PCOUNT
        CMP     AX, PMAX
        JAE     TOK1
        MOV     CX, SI
        SUB     CX, WSTART
        MOV     WLEN, CX
        CALL    LOOKUP                  ; AX = dictionary address or 0
        ; parse entry PCOUNT at parse + 2 + 4 * PCOUNT
        PUSH    AX
        MOV     AX, PCOUNT
        SHL     AX, 1
        SHL     AX, 1
        ADD     AX, OPS+2
        ADD     AX, 2
        MOV     DI, AX
        POP     DX
        CALL    WRW
        MOV     AX, DI
        ADD     AX, 2
        MOV     DX, WLEN
        CALL    WRB
        MOV     AX, DI
        ADD     AX, 3
        MOV     DX, WSTART
        INC     DX
        CALL    WRB
        INC     PCOUNT
        JMP     TOK1
TOKEND: MOV     AX, OPS+2
        INC     AX
        MOV     DX, PCOUNT
        CALL    WRB
        POP     DI
        POP     SI
        RET

;  ISSEP: CF set if AL is one of the dictionary's separators
ISSEP:  PUSH    CX
        PUSH    BX
        MOV     CX, NSEP
        CMP     CX, 16
        JBE     ISS0
        MOV     CX, 16
ISS0:   XOR     BX, BX
ISS1:   JCXZ    ISSNO
        CMP     AL, SEPS[BX]
        JE      ISSYES
        INC     BX
        DEC     CX
        JMP     ISS1
ISSYES: POP     BX
        POP     CX
        STC
        RET
ISSNO:  POP     BX
        POP     CX
        CLC
        RET

;  LOOKUP: encode INBUF[WSTART], WLEN characters, as 6 z-characters and
;  binary-search the dictionary.  AX = entry address or 0.
LOOKUP: PUSH    SI
        PUSH    DI
        ; fill ZCBUF with up to 6 z-characters (padding 5)
        PUSH    DS
        POP     ES
        MOV     DI, OFFSET ZCBUF
        MOV     CX, 9
        MOV     AL, 5
        REP     STOSB
        MOV     DI, OFFSET ZCBUF
        MOV     SI, WSTART
        MOV     CX, WLEN
LK1:    JCXZ    LK5
        CMP     DI, OFFSET ZCBUF+6
        JAE     LK5
        MOV     AL, INBUF[SI]
        INC     SI
        DEC     CX
        CMP     AL, 'a'
        JB      LK2
        CMP     AL, 'z'
        JA      LK2
        SUB     AL, 'a'-6
        MOV     [DI], AL
        INC     DI
        JMP     LK1
LK2:    ; look in alphabet 2 (entries 2-25: z-characters 8-31)
        MOV     BX, 2
LK3:    CMP     AL, ALPHA[BX+52]
        JE      LK4
        INC     BX
        CMP     BX, 26
        JB      LK3
        ; not there: 5, 6, then the 10-bit code in two halves
        MOV     BYTE PTR [DI], 5
        MOV     BYTE PTR [DI+1], 6
        MOV     AH, AL
        PUSH    CX
        MOV     CL, 5
        SHR     AH, CL
        POP     CX
        MOV     [DI+2], AH
        AND     AL, 1FH
        MOV     [DI+3], AL
        ADD     DI, 4
        JMP     LK1
LK4:    MOV     BYTE PTR [DI], 5
        ADD     BL, 6
        MOV     [DI+1], BL
        ADD     DI, 2
        JMP     LK1
LK5:    ; pack into two words
        MOV     SI, OFFSET ZCBUF
        CALL    PACK3
        MOV     KEY1, AX
        CALL    PACK3
        OR      AX, 8000H
        MOV     KEY2, AX
        ; binary search: entries DFIRST + i * DENTLEN, i in [lo, hi)
        XOR     SI, SI                  ; lo
        MOV     DI, DCOUNT              ; hi
        OR      DI, DI
        JNS     LK6
        NEG     DI                      ; a negative count means unsorted, which v3 games don't use
LK6:    CMP     SI, DI
        JAE     LKNONE
        MOV     AX, SI
        ADD     AX, DI
        SHR     AX, 1
        MOV     LKMID, AX
        MUL     DENTLEN
        ADD     AX, DFIRST
        MOV     LKADDR, AX
        CALL    RDW
        CMP     AX, KEY1
        JNE     LK7
        MOV     AX, LKADDR
        ADD     AX, 2
        CALL    RDW
        CMP     AX, KEY2
        JE      LKFOUND
LK7:    JA      LKHI                    ; entry > key: search the lower half
        MOV     SI, LKMID
        INC     SI
        JMP     LK6
LKHI:   MOV     DI, LKMID
        JMP     LK6
LKFOUND:
        MOV     AX, LKADDR
        POP     DI
        POP     SI
        RET
LKNONE: XOR     AX, AX
        POP     DI
        POP     SI
        RET

;  PACK3: AX = three z-characters at DS:SI packed (SI moves on by 3)
PACK3:  LODSB
        XOR     AH, AH
        MOV     CL, 5
        SHL     AX, CL
        OR      AL, [SI]
        INC     SI
        SHL     AX, CL
        OR      AL, [SI]
        INC     SI
        RET

; ======================================================================
;  Save and restore
; ======================================================================

;  ASKNAME: ask for a file name; FNAME / FNLEN (the default if empty)
ASKNAME:
        MOV     SI, OFFSET FILEMSG
        MOV     CX, FILEMSGL
        CALL    OUTSTR
        MOV     SI, OFFSET SAVENM
        MOV     CX, SAVELEN
        CALL    OUTSTR
        MOV     SI, OFFSET FILEMSG2
        MOV     CX, FILEMSG2L
        CALL    OUTSTR
        MOV     CX, 40
        CALL    READLINE
        MOV     CX, INLEN
        JCXZ    ASKN2
        PUSH    DS
        POP     ES
        MOV     SI, OFFSET INBUF
        MOV     DI, OFFSET FNAME
        MOV     FNLEN, CX
        REP     MOVSB
        RET
ASKN2:  PUSH    DS
        POP     ES
        MOV     SI, OFFSET SAVENM
        MOV     DI, OFFSET FNAME
        MOV     CX, SAVELEN
        MOV     FNLEN, CX
        REP     MOVSB
        RET

;  DYNROUND: AX = dynamic memory size rounded up to 512
DYNROUND:
        MOV     AX, DYNSIZE
        ADD     AX, 511
        AND     AX, 0FE00H
        RET

OPSAVE: PUSH    SI
        PUSH    DI
        MOV     AL, 13
        CALL    OUTCH
        CALL    ASKNAME
        ; the state block: magic, release, serial (PC, stack pointers and
        ; the Z-stack follow it in memory)
        MOV     SMAGIC, 5A53H
        MOV     AX, RELEASE
        MOV     SREL, AX
        MOV     ES, CHSEG
        XOR     BX, BX
        MOV     AX, ES:[BX+12H]
        MOV     SSER, AX
        MOV     AX, ES:[BX+14H]
        MOV     SSER+2, AX
        MOV     AX, ES:[BX+16H]
        MOV     SSER+4, AX
        ; open the file, creating it if need be
        MOV     DX, OFFSET FNAME
        MOV     CX, FNLEN
        MOV     BX, MODEMOD
        CALL    COPEN
        OR      AX, AX
        JZ      OPSV2
        CALL    DYNROUND
        ADD     AX, SAVESZ
        XOR     BX, BX
        MOV     DX, OFFSET FNAME
        MOV     CX, FNLEN
        CALL    CCREATE
        OR      AX, AX
        JNZ     OPSVF
        MOV     DX, OFFSET FNAME
        MOV     CX, FNLEN
        MOV     BX, MODEMOD
        CALL    COPEN
        OR      AX, AX
        JNZ     OPSVF
OPSV2:  CALL    DYNROUND
        ADD     AX, SAVESZ
        XOR     BX, BX
        CALL    CSETLEN
        OR      AX, AX
        JNZ     OPSVC
        ; dynamic memory, then the state block
        CALL    DYNROUND
        MOV     CX, AX
        MOV     ES, CHSEG
        XOR     BX, BX
        XOR     AX, AX
        XOR     DX, DX
        CALL    CWRITE
        OR      AX, AX
        JNZ     OPSVC
        CALL    DYNROUND
        PUSH    DS
        POP     ES
        MOV     BX, OFFSET SAVEBLK
        MOV     CX, SAVESZ
        XOR     DX, DX
        CALL    CWRITE
        OR      AX, AX
        JNZ     OPSVC
        MOV     AX, FHANDLE
        CALL    CCLOSE
        OR      AX, AX
        JNZ     OPSVF
        POP     DI
        POP     SI
        MOV     AL, 1
        JMP     BRANCH
OPSVC:  PUSH    AX
        MOV     AX, FHANDLE
        CALL    CCLOSE
        POP     AX
OPSVF:  CALL    IOERRMSG
        POP     DI
        POP     SI
        XOR     AL, AL
        JMP     BRANCH

;  IOERRMSG: print "Failed (error N)." for CTOS error AX
IOERRMSG:
        PUSH    AX
        MOV     SI, OFFSET FAILMSG
        MOV     CX, FAILMSGL
        CALL    OUTSTR
        POP     AX
        CALL    OUTNUM
        MOV     AL, ')'
        CALL    OUTCH
        MOV     AL, '.'
        CALL    OUTCH
        MOV     AL, 13
        JMP     OUTCH

OPRESTORE:
        PUSH    SI
        PUSH    DI
        MOV     AL, 13
        CALL    OUTCH
        CALL    ASKNAME
        MOV     DX, OFFSET FNAME
        MOV     CX, FNLEN
        MOV     BX, MODERD
        CALL    COPEN
        OR      AX, AX
        JZ      OPRS1
        JMP     OPRSF
OPRS1:  ; check the state block first, into a scratch copy
        CALL    DYNROUND
        PUSH    DS
        POP     ES
        MOV     BX, OFFSET RSTBLK
        MOV     CX, 512
        XOR     DX, DX
        CALL    CREAD
        OR      AX, AX
        JZ      OPRS2
        JMP     OPRSC
OPRS2:  CMP     RSTBLK, 5A53H
        JNE     OPRSBAD
        MOV     AX, RELEASE
        CMP     RSTBLK+2, AX
        JNE     OPRSBAD
        MOV     ES, CHSEG
        XOR     BX, BX
        MOV     AX, ES:[BX+12H]
        CMP     RSTBLK+4, AX
        JNE     OPRSBAD
        MOV     AX, ES:[BX+14H]
        CMP     RSTBLK+6, AX
        JNE     OPRSBAD
        ; good: dynamic memory, then the whole state block
        CALL    DYNROUND
        MOV     CX, AX
        MOV     ES, CHSEG
        XOR     BX, BX
        XOR     AX, AX
        XOR     DX, DX
        CALL    CREAD
        OR      AX, AX
        JNZ     OPRSDEAD
        CALL    DYNROUND
        PUSH    DS
        POP     ES
        MOV     BX, OFFSET SAVEBLK
        MOV     CX, SAVESZ
        XOR     DX, DX
        CALL    CREAD
        OR      AX, AX
        JNZ     OPRSDEAD
        MOV     AX, FHANDLE
        CALL    CCLOSE
        MOV     ES, CHSEG
        XOR     BX, BX
        AND     BYTE PTR ES:[BX+1], 8FH
        POP     DI
        POP     SI
        MOV     AL, 1
        JMP     BRANCH
OPRSBAD:
        MOV     SI, OFFSET BADSAVE
        MOV     CX, BADSAVEL
        CALL    OUTSTR
        MOV     AX, FHANDLE
        CALL    CCLOSE
        POP     DI
        POP     SI
        XOR     AL, AL
        JMP     BRANCH
OPRSDEAD:
        ; part of the game was overwritten: the only safe thing is to give up
        PUSH    AX
        MOV     SI, OFFSET DEADMSG
        MOV     CX, DEADMSGL
        CALL    OUTSTR
        POP     AX
        JMP     FATAL
OPRSC:  PUSH    AX
        MOV     AX, FHANDLE
        CALL    CCLOSE
        POP     AX
OPRSF:  CALL    IOERRMSG
        POP     DI
        POP     SI
        XOR     AL, AL
        JMP     BRANCH

; ======================================================================
;  Dispatch tables
; ======================================================================
T2OP    DW      OPBAD, OPJE, OPJL, OPJG, OPDECCHK, OPINCCHK, OPJIN, OPTEST
        DW      OPOR, OPAND, OPTATTR, OPSATTR, OPCATTR, OPSTORE, OPINSERT, OPLOADW
        DW      OPLOADB, OPGETPROP, OPGETPA, OPGETNP, OPADD, OPSUB, OPMUL, OPDIV
        DW      OPMOD, OPBAD, OPBAD, OPBAD, OPBAD, OPBAD, OPBAD, OPBAD
T1OP    DW      OPJZ, OPGETSIB, OPGETCHILD, OPGETPAR, OPGETPLEN, OPINC, OPDEC, OPPRADDR
        DW      OPBAD, OPREMOVE, OPPROBJ, OPRET, OPJUMP, OPPRPADDR, OPLOAD, OPNOT
T0OP    DW      OPRTRUE, OPRFALSE, OPPRINT, OPPRRET, OPNOP, OPSAVE, OPRESTORE, OPRESTART
        DW      OPRETPOP, OPPOP, OPQUIT, OPNEWLINE, OPSHOWST, OPVERIFY, OPBAD, OPBAD
TVAR    DW      OPCALL, OPSTOREW, OPSTOREB, OPPUTPROP, OPSREAD, OPPRCHAR, OPPRNUM, OPRANDOM
        DW      OPPUSH, OPPULL, OPNOP, OPNOP, OPBAD, OPBAD, OPBAD, OPBAD
        DW      OPBAD, OPBAD, OPBAD, OPNOP, OPNOP, OPNOP, OPBAD, OPBAD
        DW      OPBAD, OPBAD, OPBAD, OPBAD, OPBAD, OPBAD, OPBAD, OPBAD

; ======================================================================
;  Constant data
; ======================================================================
ALPHA   DB      'abcdefghijklmnopqrstuvwxyz'
        DB      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        DB      ' ', 0DH, '0123456789.,!?_#', 27H, 22H, '/\-:()'
STORY1  DB      'Zork1.dat'
STORY1L EQU     $-STORY1
STORY2  DB      '[Sys]<Sys>Zork1.dat'
STORY2L EQU     $-STORY2
SAVEEXT DB      '.sav'
SAVEEXTL EQU    $-SAVEEXT
NOPASS  DB      0
MOREMSG DB      '[MORE]'
MOREMSGL EQU    $-MOREMSG
ERRMSG  DB      'Zork: error '
ERRMSGL EQU     $-ERRMSG
PRESSMSG DB     '[Press any key to return to the Executive]'
PRESSMSGL EQU   $-PRESSMSG
NOSTORY DB      'Cannot find Zork1.dat in the current path or in [Sys]<Sys>.'
NOSTORYL EQU    $-NOSTORY
NOOPEN  DB      'Cannot open '
NOOPENL EQU     $-NOOPEN
NOMEM   DB      'Not enough memory for the story file.'
NOMEML  EQU     $-NOMEM
BADVER  DB      ' is not a version 3 story file.'
BADVERL EQU     $-BADVER
SCOREMSG DB     'Score: '
SCOREMSGL EQU   $-SCOREMSG
MOVESMSG DB     'Moves: '
MOVESMSGL EQU   $-MOVESMSG
FILEMSG DB      'File name (RETURN for '
FILEMSGL EQU    $-FILEMSG
FILEMSG2 DB     '): '
FILEMSG2L EQU   $-FILEMSG2
FAILMSG DB      'Failed (CTOS error '
FAILMSGL EQU    $-FAILMSG
BADSAVE DB      'That is not a saved game for this story.'
        DB      0DH
BADSAVEL EQU    $-BADSAVE
DEADMSG DB      'The saved game could not be read back.'
DEADMSGL EQU    $-DEADMSG

; ======================================================================
;  Variables
; ======================================================================
        EVEN
CHSEG   DW      MAXCHK DUP (0)          ; segment of each chunk
NCHUNKS DW      0
FHANDLE DW      0                       ; the file being read or written
SFHANDLE DW     0                       ; the story file (kept open)
IOCOUNT DW      0
MEMPTR  DW      0, 0
ROWS    DW      0                       ; lines in frame 0
LINELEN DW      0
MORECNT DW      0
WRAPLEN DW      0
STATPOS DW      0
OUTMODE DB      0
KBCHAR  DB      0
OPCODE  DB      0
COND    DB      0
ZSHIFT  DB      0
ZESC    DB      0
ZESCHI  DB      0
ZABBR   DB      0
STARTED DB      0
        EVEN
NOPS    DW      0
OPS     DW      8 DUP (0)
OBJTAB  DW      0
GLOBALS DW      0
DICT    DW      0
ABBREV  DW      0
DYNSIZE DW      0
RELEASE DW      0
DCH     DW      0
DOFF    DW      0
RNDLO   DW      0
RNDHI   DW      0
INMAX   DW      0
INLEN   DW      0
PMAX    DW      0
PCOUNT  DW      0
NSEP    DW      0
DENTLEN DW      0
DCOUNT  DW      0
DFIRST  DW      0
WSTART  DW      0
WLEN    DW      0
KEY1    DW      0
KEY2    DW      0
LKMID   DW      0
LKADDR  DW      0
FNLEN   DW      0
FNAME   DB      50 DUP (0)
STORYLEN DW     0
STORYNM DB      78 DUP (0)              ; the story file's name
SAVELEN DW      0
SAVENM  DB      50 DUP (0)              ; the default save file name
SEPS    DB      16 DUP (0)
ZCBUF   DB      10 DUP (0)
INBUFSZ EQU     78
INBUF   DB      80 DUP (0)
LINEBUF DB      COLS DUP (' ')
        DB      2 DUP (' ')
WRAPBUF DB      COLS DUP (0)
STATBUF DB      COLS DUP (' ')
        EVEN
RSTBLK  DW      256 DUP (0)             ; scratch for checking a save file

; The state block: written to a save file after dynamic memory.  The PC,
; the Z-stack pointers and the Z-stack itself are the live variables.
        EVEN
SAVEBLK LABEL   WORD
SMAGIC  DW      0
SREL    DW      0
SSER    DW      3 DUP (0)
PCOFF   DW      0                       ; PC: offset in chunk
PCCH    DW      0                       ; PC: chunk
ZSP     DW      0                       ; Z-stack: next free byte
ZFP     DW      0                       ; Z-stack: first local of the current routine
        DW      7 DUP (0)
ZSTK    DW      ZSTKSZ/2 DUP (0)

        DW      512 DUP (0)             ; CPU stack
        PUBLIC  STKTOP
STKTOP  LABEL   WORD
ZCODE   ENDS
        END     START

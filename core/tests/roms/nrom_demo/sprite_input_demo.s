.segment "HEADER"
  .byte "NES", $1A
  .byte 2   ; 32KB PRG (2 x 16KB banks)
  .byte 0   ; CHR-RAM (0 x 8KB banks)
  .byte 0   ; flags6: mapper 0 low nibble, horizontal mirroring
  .byte 0   ; flags7
  .byte 0,0,0,0,0,0,0,0 ; bytes 8-15: PRG-RAM size, TV system, unused padding (iNES header is 16 bytes total)

PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
OAMADDR   = $2003
OAMDATA   = $2004
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007
OAMDMA    = $4014
JOY1      = $4016
JOY2      = $4017

SPRITE_X = $10
SPRITE_Y = $11

.segment "CODE"

reset:
  sei
  cld
  ldx #$00
  stx PPUCTRL
  stx PPUMASK

@vwait1:
  bit PPUSTATUS
  bpl @vwait1

  ldx #$00
  lda #$FF
@clroam:
  sta $0200,x
  inx
  bne @clroam

  lda #$70
  sta $0200
  sta SPRITE_Y
  lda #$01
  sta $0201
  lda #$00
  sta $0202
  lda #$80
  sta $0203
  sta SPRITE_X

  lda #$00
  sta PPUADDR
  lda #$10
  sta PPUADDR
  ldx #$10
  lda #$FF
@fillchr:
  sta PPUDATA
  dex
  bne @fillchr

  ; universal backdrop ($3F00, shared by bg and sprites alike)
  lda #$3F
  sta PPUADDR
  lda #$00
  sta PPUADDR
  lda #$0F
  sta PPUDATA

  ; sprite palette group 0's pixel-value-3 entry ($3F10 + 0*4 + 3 = $3F13)
  ; -- *not* $3F00-$3F03, which is the *background* palette's group 0.
  lda #$3F
  sta PPUADDR
  lda #$13
  sta PPUADDR
  lda #$21
  sta PPUDATA

@vwait2:
  bit PPUSTATUS
  bpl @vwait2

  lda #$00
  sta PPUSCROLL
  sta PPUSCROLL
  lda #$1E
  sta PPUMASK
  ; NMI-driven from here on -- a tight `bit PPUSTATUS`/`bpl` poll loop can
  ; pathologically self-synchronize with the PPU's dot timing and land every
  ; single poll read exactly on the one-PPU-clock-early suppression window
  ; (see `Ppu.readRegister`'s $2002 case), locking the VBL flag "suppressed"
  ; forever once it happens to align -- confirmed empirically while writing
  ; this fixture. NMI sidesteps that entirely: it is driven by the PPU's own
  ; edge-triggered signal, sampled every CPU cycle regardless of what the
  ; program is doing, exactly like every real commercial NES game's frame
  ; loop (never raw `$2002` polling) for precisely this reason.
  lda #$80
  sta PPUCTRL

forever:
  jmp forever

nmi:
  pha
  txa
  pha
  tya
  pha

  lda #$02
  sta OAMDMA

  lda #$01
  sta JOY1
  lda #$00
  sta JOY1

  lda JOY1
  lda JOY1
  lda JOY1
  lda JOY1
  lda JOY1
  and #$01
  beq notup
  dec SPRITE_Y
notup:
  lda JOY1
  and #$01
  beq notdown
  inc SPRITE_Y
notdown:
  lda JOY1
  and #$01
  beq notleft
  dec SPRITE_X
notleft:
  lda JOY1
  and #$01
  beq notright
  inc SPRITE_X
notright:

  lda SPRITE_X
  sta $0203
  lda SPRITE_Y
  sta $0200

  pla
  tay
  pla
  tax
  pla
  rti

.segment "VECTORS"
  .word nmi
  .word reset
  .word reset

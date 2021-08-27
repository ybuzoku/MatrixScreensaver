;-----------------------------------------------------------------------:
; A true matrix screensaver, this version works ONLY in bw modes	:
; Use command tail in PSP as stack and local var space			:
; Written by: Yll Buzoku						:
; Date: 27/08/2021							:
;-----------------------------------------------------------------------:
CODE 	SEGMENT
ASSUME 	CS:CODE, DS:CODE, ES:CODE, SS:CODE
;-----------------------------------------------------------------------:
; PSP equates area.							:
;-----------------------------------------------------------------------:
ORG 	0FFh 
VARS	PROC	NEAR
stkend	db 	?	;Stack tail, max 60 bytes, go into FCB area
seed	dw	?	;RNG seed value, overlay jmp TRANS
inFlag	db	?	;Bits [7:1] reserved, Bit [0]-inTSR flag
VARS	ENDP
;-----------------------------------------------------------------------:
ORG 	100H
EP	PROC	NEAR
	jmp TRANS	;Just save a word by recycling this instruction
curs	dw	?	;Saves BDA cursor word before modification
ticks	dw	?	;Timeout comparator var, 0888h is 2 minutes
ogss	dw	?	;Caller stack segment
ogsp	dw	?	;Caller stack pointer
EP	ENDP	

TSRMAIN	PROC	NEAR
;Saves current screen and starts scrolling ascii chars down the screen. 
;First manually set segregs
	cli
	mov word ptr cs:[ogsp], sp
	mov sp, ss
	mov word ptr cs:[ogss], sp
	mov sp, cs	;Move code segment into ss
	mov ss, sp
	mov sp, word ptr cs:[stkend] ;Point sp to offset of the bottom of stk
	sti
	
	push ax
	push bx
	push cx
	push dx
	push ds
	push es
	push si
	push di
;Reset segvars
	push cs
	pop ax
	mov ds, ax
	mov es, ax
;Now detect video mode
	;mov ah, 0Fh
	;int 10h
;Returns al=Vid mode, ah=#of cols, bh=active page
	;mov byte ptr [mode], al
	;mov byte ptr [cols], ah
	;mov byte ptr [page], bh
	;mov word ptr [regseg], 0b800h	;Assume colour card
	;cmp al, 07h	;Are we a BW card, currently active?
	;jne i1
	;sub word ptr [regseg], 800h	;Move it back to bw space
i1:
	;First we create a first seed
	xor ah, ah
	int 1Ah
	mov word ptr [seed], dx		;Get ticks into seed var

	xor bh, bh		;0 page
	mov ah, 03h		;read cursor pos
	int 10h
	mov word ptr [curs], dx	;Save cursor pos

;	mov ax, word ptr [regseg]	;Get actual segment 
	mov ax, 0b000h			;Load bw seg
	push ds
	mov ds, ax			;Set ds to point to bios regen
	xor si, si
	mov di, OFFSET regen		;es points to current code segment
	mov cx, 2000			;2000 words to be transferred
	rep movsw
	pop ds				;Get original ds back
;Buffers copied, time for some fun!
iloop:		;Main loop of this meme

;	mov bl, byte ptr [cols]	
	mov bl, 80	;80 columns, hardcoded
	call rndgen
	mov al, bl	;Move the random column into al
			;Get a random column function
	mov bl, 0FFh	;Sub function options
	call rndgen
	mov ah, bl	;Move random column function into ah
	call col

	test byte ptr [inFlag], 1	;Will only be zero if key pressed
	jnz iloop
iexit:
;Exit below here. Return regen to regseg
	push cs
	pop ds
;	mov ax, word ptr [regseg]
	mov ax, 0b000h	;bw seg
	mov es, ax
	mov si, OFFSET regen
	xor di, di
	mov cx, 2000
	rep movsw
	mov dx, word ptr [curs]	;Get original cursor position back
	xor bh, bh		;0 page
	mov ah, 02h		;set cursor
	int 10h

	pop di
	pop si
	pop es
	pop ds
	pop dx
	pop cx
	pop bx
	pop ax
	cli
	mov sp, word ptr cs:[ogss]
	mov ss, sp
	mov sp, word ptr cs:[ogsp]
	sti
	iret	;Alternate exit point, when exiting from screensaver
TSRMAIN ENDP

IRQ0	PROC	FAR	;Timer replacement
;Timer initiates whether or not to go into screensaver
;Wraps old int 09h, to continue gracefully after hardware EOI
	jmp short irq0in
	dw	55AAh	;Installed signature
irq0in:
	pushf		;Fake interrupt call, could just inc sp
	db 09Ah		;Far Call, manually encoded
irq0o:	dw ?
irq0s:	dw ?		
	test byte ptr cs:[inFlag], 1
	jnz irq0cont		;If its 1, dont inc ticks, proceed as normal
	inc word ptr cs:[ticks]
;DEBUG DEBUG DEBUG DEBUG DEBUG
;	cmp word ptr cs:[ticks], 0B6h	;Temp 10 seconds 0888h
;DEBUG DEBUG DEBUG DEBUG DEBUG
	cmp word ptr cs:[ticks], 0888h
	jb irq0cont

	inc byte ptr cs:[inFlag]  ;Set bit 0, indicate going into TSR
	mov word ptr cs:[ticks], 0
	jmp tsrmain
irq0cont:
	iret
IRQ0	ENDP

IRQ1	PROC	FAR	;Keyb replacement
	mov word ptr cs:[ticks], 0	;Null out the ticks counter
	mov byte ptr cs:[inFlag],0
	db	0EAh	;Far jump to original interrupt handler
irq1o:	dw	?	;Var space for og handler/part of opcode
irq1s:	dw	?
IRQ1	ENDP

RNDGEN	PROC	NEAR
;----------------------------------------------------
; Generates a random 8 bit value and returns it.    :
; Input: bl = Modulo value (max value plus 1).	    :
; Ret:	bl = Random return value.		    :
; All registers preserved.			    :
;----------------------------------------------------
	push ax
	push cx
	push dx
	mov ax, 25173	;Random multiplier
	mul word ptr [seed]	;Multiply to seed
	add ax, 13849
	mov word ptr [seed], ax
;ax now has new random value
	mov cl, bl	;Get max number in cl
	xor ch, ch
	xor dx, dx	;Clear upper word for division for no overflow?
	div cx		;Divide ax by cl
	mov bl, dl	;move remainder into bl

	pop dx
	pop cx
	pop ax
	ret
RNDGEN	ENDP

COL	PROC	NEAR
;-----------------------------------------------------
; Takes column to scroll down, and scrolls it down.  :
; Might generate a new char or even clear column.    :
; Input:  al=Column number (0-49), ah=Bit 7 	     :
;	  ah(7) clear = Scroll column		     :
;	  ah(7) set   = Add new char + scroll	     :
; Output: Nothing, ax destroyed.		     :
;-----------------------------------------------------
	push dx
	push cx
	push bx
	push si	
	
	xor ch, ch	;Upper row
	mov dh, 24	;Lower row
	mov cl, al	;Column to scroll in cl
	mov dl, al	;Column to scroll in dl
	mov si, ax	;Save col number in si
	mov bx, 0700h	;Usual char attrib in bh
	test ah, 80h
	jz colsub0

	mov ax, 0701h	;Scroll col down 1
	int 10h
	;Now insert a new random char at top
	mov dx, si	;Return col number into dl
	xor dh, dh	;Row 0
	xor bh, bh	;Page 0
	mov ah, 02h	;Set cursor pos
	int 10h
	mov bl, 0FFh	;Max ASCII char value
	call rndgen	;Get the char
	mov cx, 1	;1 char to print
	mov al, bl	;Move char code into al
	mov bh, 00h	;Page number
	mov ah, 0Ah	;Write char function
	int 10h
	jmp short colexit
colsub0:
	mov ax, 0701h	;Scroll col down 1
	int 10h
colexit:
	pop si
	pop bx
	pop cx
	pop dx
	ret
COL	ENDP
regen:	db	4000 	dup(?)	;Regen space
;Jettison the code below here
TRANS 	PROC	NEAR	;Transient loader
	mov ax, 3508h	;Int 08h, timer hook, to look for signature
	int 21h
	push cs
	pop ds	;Fix ds to current cs
	cmp word ptr es:[bx+2], 55AAh	;Check signature
	jne proceed
	mov dx, OFFSET instmsg
	mov ah, 09h
	int 21h
	mov ax, 4c00h
	int 21h
instmsg: db 'Screensaver already installed!',0Ah,0Dh, '$'
proceed:
;Initialise variables
	mov word ptr [ticks], 0
	mov byte ptr [inFlag], 0
;Turn off interrupts, install handlers
	cli
	mov ax, 3508h
	int 21h		;Save old values
	mov word ptr [irq0o], bx
	mov bx, es
	mov word ptr [irq0s], bx

	mov ax,3509h
	int 21h
	mov word ptr [irq1o], bx
	mov bx, es
	mov word ptr [irq1s], bx

	mov dx, OFFSET IRQ0
	mov ax, 2508h	;ah=25 setvector, al=Int 08h
	int 21h

	push cs	;Reset ds incase int21h clobbers it
	pop ds
	mov dx, OFFSET IRQ1
	mov ax, 2509h
	int 21h

	sti	;Restart Interrupts
;Print install message
	push cs
	pop ds
	mov dx, OFFSET sucmsg
	mov ah, 09h
	int 21h	;Print string
;Compute size for TSR
	mov ax, OFFSET TRANS
	mov cl, 4
	shr ax, cl	;Turn number of bytes into paragraphs
	inc ax		;Add one for good measure
	mov dx, ax
	mov ax, 3100h
	int 21h
sucmsg:	db	"Successfully connected to the matrix!",0Ah,0Dh,"$"
TRANS	ENDP

CODE	ENDS
	END	EP

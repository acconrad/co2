#lang racket
;; co2 Copyright (C) 2016 Dave Griffiths
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.
;;
;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

(require racket/cmdline)
(require data/gvector)

;; internal compiler register on zero page
(define working-reg "$ff")
(define stack-frame-h "$fe")
(define stack-frame-l "$fd")
(define rnd-reg "$fc")

(define reg-table
  ;; ppu registers
  '((REG-PPU-CTRL             #x2000)
    (REG-PPU-MASK             #x2001)
    (REG-PPU-STATUS           #x2002)
    (REG-OAM-ADDR             #x2003)
    (REG-OAM-DATA             #x2004)
    (REG-PPU-SCROLL           #x2005)
    (REG-PPU-ADDR             #x2006)
    (REG-PPU-DATA             #x2007)
    ;;  apu registers
    (REG-APU-PULSE1-CONTROL   #x4000)
    (REG-APU-PULSE1-RAMP      #x4001)
    (REG-APU-PULSE1-FT        #x4002)
    (REG-APU-PULSE1-CT        #x4003)
    (REG-APU-PULSE2-CONTROL   #x4004)
    (REG-APU-PULSE2-RAMP      #x4005)
    (REG-APU-PULSE2-FT        #x4006)
    (REG-APU-PULSE2-CT        #x4007)
    (REG-APU-TRI-CONTROL      #x4008)
    (REG-APU-TRI-FT           #x400a)
    (REG-APU-TRI-CT           #x400b)
    (REG-APU-NOISE-ENV        #x400c)
    (REG-APU-NOISE-FT         #x400e)
    (REG-APU-NOISE-CT         #x400f)
    (REG-APU-DMC-CONTROL      #x4010)
    (REG-APU-DMC-DAC          #x4011)
    (REG-APU-DMC-ADDR         #x4012)
    (REG-APU-DMC-SIZE         #x4013)
    (REG-OAM-DMA              #x4014)
    (REG-APU-CHANNEL          #x4015)
    ;; input
    (REG-JOYPAD-0             #x4016)
    (REG-JOYPAD-1             #x4017)))

(define ppu-flags
  ;; TODO: More
  '((PPU-CTRL-NMI                #x80)
    (PPU-MASK-SHOW-SPR           #x10)
    (PPU-MASK-SHOW-BG            #x08)))

(define reserved-zero-page
  '((ppu-ctrl                    #x00)
    (ppu-mask                    #x01)
    (frame-num                   #x02)
    (-count                      #x03)
    (-tmp                        #x04)))

(define (reg-table-lookup x)
  (let ((lu (assoc x reg-table)))
    (if lu (cadr lu) #f)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Label generation

(define label-id 0)

(define (generate-label name)
  (set! label-id (+ label-id 1))
  (string-append "_" name "_" (left-pad (number->string label-id 16) #\0 4)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Symbol / label definitions. Stores vars, consts, addresses, data.

(define var-allocation #x10)

(define sym-label-defs (list (make-hash)))

(define data-segment '())

(struct sym-label (sym name address kind))

(define (make-variable! sym #:label [label #f])
  (let* ((name (normalize-name sym))
         (n var-allocation))
    (when label
          (set! name label))
    (when (not (hash-has-key? (car sym-label-defs) sym))
          (hash-set! (car sym-label-defs) sym (sym-label sym name n 'var))
          (set! var-allocation (+ 1 var-allocation)))
    (hash-ref (car sym-label-defs) sym)))

(define (make-address! sym addr)
  (let ((name (normalize-name sym)))
    (hash-set! (car sym-label-defs) sym (sym-label sym name addr 'addr))
    (hash-ref (car sym-label-defs) sym)))

(define (make-const! sym value)
  (let ((name (normalize-name sym)))
    (hash-set! (car sym-label-defs) sym (sym-label sym name value 'const))
    (hash-ref (car sym-label-defs) sym)))

(define (make-data! sym value)
  (let ((name (normalize-name sym)))
    (set! data-segment (cons (list name value) data-segment))
    (hash-set! (car sym-label-defs) sym (sym-label sym name 0 'data))
    (hash-ref (car sym-label-defs) sym)))

(define (variable? sym)
  (let ((lookup (sym-label-lookup)))
    (and lookup (eq? (sym-label-kind lookup) 'var))))

(define (address? sym)
  (let ((lookup (sym-label-lookup)))
    (and lookup (eq? (sym-label-kind lookup) 'addr))))

(define (const? sym)
  (let ((lookup (sym-label-lookup)))
    (and lookup (eq? (sym-label-kind lookup) 'const))))

(define (sym-label-lookup sym)
  (define (_ table parents)
    (if (hash-has-key? table sym)
        (hash-ref table sym)
        (if (null? parents)
            #f
            (_ (car parents) (cdr parents)))))
  (_ (car sym-label-defs) (cdr sym-label-defs)))

(define (sym-label-push-scope)
  (set! sym-label-defs (cons (make-hash) sym-label-defs)))

(define (sym-label-pop-scope)
  (set! sym-label-defs (cdr sym-label-defs)))

(define (get-data-segment)
  data-segment)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Function definition

(define function-defs (make-hash))

(define (make-function! sym)
  (let* ((name (normalize-name sym))
         (n (hash-count function-defs)))
    (when (not (hash-has-key? function-defs name))
          (hash-set! function-defs name n))
    (hash-ref function-defs name)))

(define (function? name)
  (hash-has-key? function-defs (normalize-name name)))

;;----------------------------------------------------------------
; TODO: Combine with other utilities, or remove when replaced.

(define (dash->underscore s)
  (foldl
   (lambda (c r)
     (if (eq? c #\-)
         (string-append r "_")
         (string-append r (string c))))
   ""
   (string->list s)))

(define (is-fnarg? x)
  ; TODO: Remove.
  #f)

(define (immediate-value x)
  ; TODO: Remove.
  #f)

(define (emit-expr x)
  ; TODO: Remove.
  #f)

(define (assert val fn)
  (when (not (fn val))
    (error (format "assert failed: ~a ~a" val fn))))

;;----------------------------------------------------------------
; Emit

(define *result* (make-gvector))

(define (emit . args)
  (let ((build ""))
    ; Optional label.
    (when (and (not (null? args)) (string? (car args)))
          (set! build (car args))
          (set! args (cdr args)))
    ; Symbol for opcode...
    (when (not (null? args))
          (set! build (string-append build "  " (symbol->string (car args))))
          ; ...followed by optional string.
          (when (not (null? (cdr args)))
                (if (string=? build "")
                    (set! build (cadr args))
                    (set! build (string-append build " " (cadr args))))))
    (gvector-add! *result* build)))

(define (emit-blank)
  (gvector-add! *result* ""))

(define (emit-context)
  (gvector-add! *result* (co2-source-context)))

(define (emit-label label)
  (gvector-add! *result* (format "~a:" label)))

;;----------------------------------------------------------------
; TODO: Reintroduce these utilities back into the evaluator.

;; takes an address literal
(define (emit-set16! x)
  (if (is-fnarg? (cadr x))
      (begin
        (display "ERROR: trying to set fn arg to 16bit value...")
        (newline))
      (append
       (emit 'lda (string-append "#<" (symbol->string (caddr x))))
       (emit 'sta (immediate-value (cadr x)))
       (emit 'ldx "#1")
       (emit 'lda (string-append "#>" (symbol->string (caddr x))))
       (emit 'sta (immediate-value (cadr x)) ",x"))))

(define (emit-poke! x)
  ;; address offset is optional
  (if (eq? (length x) 4)
      (append
       (emit-expr (list-ref x 3)) ;; value
       (emit 'pha)
       (emit-expr (list-ref x 2)) ;; address offset
       (emit 'tay)
       (emit 'pla)
       (emit 'sta (immediate-value (list-ref x 1)) ",y"))
      (append
       (emit-expr (list-ref x 2)) ;; value
       (emit 'sta (immediate-value (list-ref x 1))))))

(define (emit-peek x)
  ;; address offset is optional
  (if (eq? (length x) 3)
      (append
       (emit-expr (list-ref x 2)) ;; address offset
       (emit 'tay)
       (emit 'lda (immediate-value (list-ref x 1)) ",y"))
      (append
       (emit 'lda (immediate-value (list-ref x 1))))))

(define (emit-peek16 x)
  ;; address offset is optional
  (if (eq? (length x) 3)
      (append
       (emit-expr (list-ref x 2)) ;; address offset
       (emit 'tay)
       (emit 'lda (string-append "(" (immediate-value (list-ref x 1)) "),y")))
      (append
       (emit 'ldy "#0")
       (emit 'lda (string-append "(" (immediate-value (list-ref x 1)) "),y")))))

;; sets blocks of 256 bytes
;; (set-page variable/value expr)
(define (emit-memset x)
  (append
   (emit-expr (caddr x))
   (emit 'ldx "#$00")
   (emit "-" 'sta (immediate-value (cadr x)) ",x")
   (emit 'inx)
   (emit 'bne "-")))

; (memset base-symbol high-offset low-offset length value)
(define (emit-ppu-memset x)
  (append
   (emit-expr (list-ref x 2)) ;; dest offset high
   (emit 'clc)
   (emit 'adc (car (immediate-value (list-ref x 1))))
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit-expr (list-ref x 3)) ;; dest offset low
   (emit 'clc)
   (emit 'adc (cadr (immediate-value (list-ref x 1))))
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit-expr (list-ref x 5)) ;; value
   (emit 'pha)
   (emit-expr (list-ref x 4)) ;; length
   (emit 'tax)
   (emit 'pla)
   (emit "-" 'sta (reg-table-lookup 'reg-ppu-data))
   (emit 'dex)
   (emit 'bne "-")
   ;; reset ppu addr
   (emit 'lda "#$00")
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit 'lda "#$00")
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))))


; (memcpy base-symbol high-offset low-offset prg-end prg-base prg-start)
(define (emit-ppu-memcpy x)
  (append
   (emit-expr (list-ref x 2)) ;; dest offset high
   (emit 'clc)
   (emit 'adc (car (immediate-value (list-ref x 1))))
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit-expr (list-ref x 3)) ;; dest offset low
   (emit 'clc)
   (emit 'adc (cadr (immediate-value (list-ref x 1))))
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit 'ldx (immediate-value (list-ref x 6))) ;; start addr
   (emit "-" 'lda (immediate-value (list-ref x 5)) ",x") ;; base addr
   (emit 'sta (reg-table-lookup 'reg-ppu-data))
   (emit 'inx)
   (emit 'cpx (immediate-value (list-ref x 4))) ;; end addr
   (emit 'bne "-")
   ;; reset ppu addr
   (emit 'lda "#$00")
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit 'lda "#$00")
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))))

; (memcpy base-symbol high-offset low-offset prg-end prg-base-h prg-base-l)
(define (emit-ppu-memcpy16 x)
  (display (immediate-value (list-ref x 5)))(newline)
  (append
   (emit-expr (list-ref x 2)) ;; dest offset high
   (emit 'clc)
   (emit 'adc (car (immediate-value (list-ref x 1))))
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit-expr (list-ref x 3)) ;; dest offset low
   (emit 'clc)
   (emit 'adc (cadr (immediate-value (list-ref x 1))))
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit 'ldy "#0")
   (emit "-" 'lda (string-append "(" (immediate-value (list-ref x 5)) "),y"))
   (emit 'sta (reg-table-lookup 'reg-ppu-data))
   (emit 'iny)
   (emit 'cpy (immediate-value (list-ref x 4))) ;; end addr
   (emit 'bne "-")
   ;; reset ppu addr
   (emit 'lda "#$00")
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))
   (emit 'lda "#$00")
   (emit 'sta (reg-table-lookup 'reg-ppu-addr))))


;; optimised version of poke for sprites
(define (emit-set-sprite! n x)
  ;; address offset is optional
  (append
   (emit-expr (list-ref x 2)) ;; value
   (emit 'pha)
   (emit-expr (list-ref x 1)) ;; sprite num offset
   (emit 'asl) ;; *2
   (emit 'asl) ;; *4
   (emit 'clc)
   (emit 'adc (immediate-value n)) ;; byte offset
   (emit 'tay)
   (emit 'pla)
   (emit 'sta "$200,y")))

;; optimised version of peek for sprites
(define (emit-get-sprite n x)
  ;; address offset is optional
  (append
   (emit-expr (list-ref x 1)) ;; sprite num offset
   (emit 'asl) ;; *2
   (emit 'asl) ;; *4
   (emit 'clc)
   (emit 'adc (immediate-value n)) ;; byte offset
   (emit 'tay)
   (emit 'lda "$200,y")))

;; optimised version of poke for sprites
(define (emit-zzz-sprites! n zzz x)
  (let ((label (generate-label "sprite_range")))
    (append
     (emit-expr (list-ref x 3)) ;; value
     (emit 'pha)
     (emit-expr (list-ref x 2)) ;; sprite count
     (emit 'pha)
     (emit-expr (list-ref x 1)) ;; sprite num offset
     (emit 'asl) ;; *2
     (emit 'asl) ;; *4
     (emit 'clc)
     (emit 'adc (immediate-value n)) ;; byte offset
     (emit 'tay) ;; put offset in y
     (emit 'pla) ;; pull count out
     (emit 'tax) ;; put sprite count in x
     (emit 'pla) ;; value
     (emit 'sta working-reg)
     (emit-label label)
     (emit 'lda "$200,y") ;; load previous
     (cond
      ((equal? zzz "adc") (emit "clc")) ;; clear carry
      ((equal? zzz "sbc") (emit "sec")) ;; set carry
      (else '()))
     (emit zzz working-reg)
     (emit 'sta "$200,y")
     (emit 'iny) ;; skip
     (emit 'iny) ;; to
     (emit 'iny) ;; the next
     (emit 'iny) ;; sprite
     (emit 'dex)
     (emit 'bne label))))

;; optimised version of poke for sprites
(define (emit-set-sprites-x-2x2! x)
  (append
   (emit-expr (list-ref x 2)) ;; value
   (emit 'pha)
   (emit-expr (list-ref x 1)) ;; sprite addr
   (emit 'tay) ;; put offset in y
   (emit 'pla) ;; value
   (emit 'sta "$203,y")
   (emit 'sta "$20b,y")
   (emit 'clc)
   (emit 'adc "#8")
   (emit 'sta "$207,y")
   (emit 'sta "$20f,y")))

(define (emit-set-sprites-y-2x2! x)
  (append
   (emit-expr (list-ref x 2)) ;; value
   (emit 'pha)
   (emit-expr (list-ref x 1)) ;; sprite addr
   (emit 'tay) ;; put offset in y
   (emit 'pla) ;; value
   (emit 'sta "$200,y")
   (emit 'sta "$204,y")
   (emit 'clc)
   (emit 'adc "#8")
   (emit 'sta "$208,y")
   (emit 'sta "$20c,y")))

;; optimised version of poke for sprites
(define (emit-animate-sprites-2x2! x)
  (append
   (emit-expr (list-ref x 2)) ;; value
   (emit 'pha)
   (emit-expr (list-ref x 1)) ;; sprite num offset
   (emit 'asl) ;; *2
   (emit 'asl) ;; *4
   (emit 'tay) ;; put offset in y
   (emit 'iny) ;; id byte offset
   (emit 'pla) ;; value
   (emit 'sta "$200,y") ;; sprite 1
   ;;(emit "clc")
   (emit 'adc "#$01")
   (emit 'sta "$204,y") ;; sprite 2
   (emit 'adc "#$0f")
   (emit 'sta "$208,y") ;; sprite 3
   (emit 'adc "#$01")
   (emit 'sta "$20c,y"))) ;; sprite 4

(define (emit-mul x)
  (let ((label (generate-label "mul")))
    (append
     (emit-expr (cadr x))
     (emit 'pha)
     (emit-expr (caddr x))
     (emit 'sta working-reg)
     (emit 'dec working-reg)
     (emit 'pla)
     (emit 'tax)
     (emit-label label)
     (emit 'clc)
     (emit 'adc working-reg)
     (emit 'dex)
     (emit 'bne label))))

;; add two 8 bit numbers to a 16 bit one
(define (emit-add16 x)
  (append
   (emit-expr (list-ref x 2)) ; high 8 bit num
   (emit 'pha)
   (emit-expr (list-ref x 3)) ; low 8 bit num
   (emit 'sta working-reg)
   (emit 'clc)
   (emit 'lda (string-append "(" (immediate-value (list-ref x 1)) ")") )
   (emit 'adc working-reg)
   (emit 'sta (string-append "(" (immediate-value (list-ref x 1)) ")"))
   (emit 'pla)
   (emit 'sta working-reg)
   (emit 'lda (string-append "(" (immediate-value (list-ref x 1)) "+1)"))
   (emit 'adc working-reg)
   (emit 'sta (string-append "(" (immediate-value (list-ref x 1)) "+1)"))))

;; subtract two 8 bit numbers to a 16 bit one
(define (emit-sub16 x)
  (append
   (emit-expr (list-ref x 2)) ; high 8 bit num
   (emit 'pha)
   (emit-expr (list-ref x 3)) ; low 8 bit num
   (emit 'sta working-reg)
   (emit 'sec)
   (emit 'lda (string-append "(" (immediate-value (list-ref x 1)) ")") )
   (emit 'sbc working-reg)
   (emit 'sta (string-append "(" (immediate-value (list-ref x 1)) ")"))
   (emit 'pla)
   (emit 'sta working-reg)
   (emit 'lda (string-append "(" (immediate-value (list-ref x 1)) "+1)"))
   (emit 'sbc working-reg)
   (emit 'sta (string-append "(" (immediate-value (list-ref x 1)) "+1)"))))

;----------------------------------------------------------------
; TODO: Use these for built-in macros.

(define (preprocess-cond-to-if x)
  (define (_ l)
    (cond
      ((null? l) 0)
      ((eq? (pre-process (caar l)) 'else) (cons 'do
                                                (pre-process (cdr (car l)))))
      (else (list 'if (pre-process (caar l))
                  (cons 'do (pre-process (cdr (car l))))
                  (_ (cdr l))))))
  (_ (cdr x)))

;; (get-sprite-vflip sprite-num)
(define (preprocess-get-sprite-vflip x)
  (list '>> (list 'get-sprite-attr (cadr x)) 7))

(define (preprocess-get-sprite-hflip x)
  (list 'and (list '>> (list 'get-sprite-attr (cadr x)) 6) #x01))

(define (preprocess-set-sprite-vflip! x)
  (list 'set-sprite-attr! (list-ref x 1) (list '<< (list-ref x 2) 6)))

(define (preprocess-set-sprite-hflip! x)
  (list 'set-sprite-attr! (list-ref x 1) (list '<< (list-ref x 2) 7)))

;; basically diy-macro from the main tinyscheme stuff
(define (pre-process s)
  (cond
    ((null? s) s)
    ((list? s)
     (map
      (lambda (i)
        (if (and (list? i) (not (null? i)))
            ;; dispatch to macro processors
            (cond
             ((eq? (car i) 'cond) (preprocess-cond-to-if i))
             ((eq? (car i) 'get-sprite-vflip) (preprocess-get-sprite-vflip i))
             ((eq? (car i) 'get-sprite-hflip) (preprocess-get-sprite-hflip i))
             ((eq? (car i) 'set-sprite-vflip!) (preprocess-set-sprite-vflip! i))
             ((eq? (car i) 'set-sprite-hflip!) (preprocess-set-sprite-hflip! i))
             (else (pre-process i)))
            (pre-process i)))
      s))
    (else s)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Utilities

(define (find-keyword keyword elems)
  (if (or (empty? elems) (empty? (cdr elems)))
      #f
      (if (eq? keyword (car elems))
          (cadr elems)
          (find-keyword keyword (cddr elems)))))

(define (->string x)
  (call-with-output-string
   (lambda (out)
     (display x out))))

(define (left-pad text pad len)
  (if (>= (string-length text) len)
      text
      (string-append (make-string (- len (string-length text)) pad) text)))

(define (normalize-name name)
  (dash->underscore (symbol->string name)))

(define (atom? obj)
  (and (not (null? obj))
       (not (pair? obj))))

(define (list->byte-string ls)
  (string-join (map (lambda (x)
                      (string-append "$" (left-pad (format "~x" x) #\0 2))) ls)
               ","))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Source file context information for debugging / compiler metadata

(define *co2-source-form* (make-parameter #f))

(define (co2-source-context)
  (let* ((form (*co2-source-form*))
         (fname (syntax-source form))
         (line-num (syntax-line form))
         (source (->string (syntax->datum form)))
         (len (min 40 (string-length source))))
    (format ";~a:~a ~a" fname line-num (substring source 0 len))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Built-in functions

(define (built-in-nes-header num-prg num-chr mapper mirroring)
  (let ((third-byte (+ (* mapper #x10) (if (eq? mirroring 'vertical) 1 0))))
    (emit-context)
    (emit ".byte \"NES\",$1a")
    (emit (format ".byte $~x" (or num-prg 1)))
    (emit (format ".byte $~x" (or num-chr 0)))
    (emit (format ".byte $~x" third-byte))
    (emit (format ".byte ~a"
                  (string-join (build-list 9 (lambda (x) "$0")) ",")))
    (emit "")
    (emit ".org $c000")
    (emit "")))

(define (built-in-init-system)
  ;; disable interrupts while we set stuff up
  (emit 'sei)
  ;; make sure we're not using decimal mode
  (emit 'cld)
  ;; wait for 2 vblanks
  (emit "-" 'lda "$2002")
  (emit 'bpl "-")
  (emit "-" 'lda "$2002")
  (emit 'bpl "-")
  ;; clear out all ram
  (emit 'ldx "#$00")
  (emit "-" 'lda "#$00")
  (emit 'sta "$000,x")
  (emit 'sta "$100,x")
  (emit 'sta "$300,x")
  (emit 'sta "$400,x")
  (emit 'sta "$500,x")
  (emit 'sta "$600,x")
  (emit 'sta "$700,x")
  (emit 'lda "#$ff")
  (emit 'sta "$200,x")
  (emit 'inx)
  (emit 'bne "-")
  ;; reset the stack pointer.
  (emit 'ldx "#$ff")
  (emit 'txs))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Keep track of function calls to build a call tree. Used to determine
; memory addresses for local vars and function arguments.

(define func-nodes (make-hash))

(struct func-node (name params calls [memory #:mutable]))

(define (make-func-node! name params calls)
  (hash-set! func-nodes name (func-node name params calls #f)))

(define *invocations* (make-parameter #f))

(define *entry-points* '())

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Main processor.

(define (process-defvar name)
  (let* ((def (normalize-name name))
         (sym-label (make-variable! name))
         (addr (sym-label-address sym-label)))
    (emit-blank)
    (emit-context)
    (emit (format "~a = $~a" def (left-pad (number->string addr 16) #\0 2)))))

(define (process-defconst name value)
  (let* ((def (normalize-name name))
         (sym-label (make-const! name value))
         (value (sym-label-address sym-label)))
    (emit-blank)
    (emit-context)
    (emit (format "~a = $~a" def (left-pad (number->string value 16) #\0 2)))))

(define (process-proc type context-decl body)
  (assert type symbol?)
  (assert context-decl syntax?)
  (assert body list?)
  (let* ((decl (syntax->datum context-decl))
         (name (car decl))
         (args (cdr decl)))
    ; Add vector entry points.
    (when (eq? type 'vector)
          (set! *entry-points* (cons name *entry-points*)))
    (parameterize ([*invocations* (make-gvector)])
      ; TODO: Add number of parameters to table, to check when called.
      (make-function! name)
      (emit-blank)
      (emit-context)
      (emit-label (normalize-name name))
      ; Push scope for local variables.
      (sym-label-push-scope)
      ; Fastcall parameters
      (for ([sym args] [i (in-naturals)])
           (let ((label (format "_~a__~a" (normalize-name name)
                                (normalize-name sym))))
             (make-variable! sym #:label label)
             (cond
              ([= i 0] (emit 'sta (as-arg sym)))
              ([= i 1] (emit 'stx (as-arg sym)))
              ([= i 2] (emit 'sty (as-arg sym))))))
      ; Additional parameters
      (when (> (length args) 3)
            (emit 'tsx)
            (let ((params (cdddr args)))
              (for ([p params] [i (in-naturals)])
                   ; TODO: Get parameter from the stack, store in local frame.
                   (emit 'lda (format "$~x,x" (+ #x103 i)))
                   (emit 'sta (as-arg p)))))
      ; Process body.
      (for ([stmt body])
           (process-form stmt))
      ; Pop scope.
      (sym-label-pop-scope)
      ; Return from function.
      (cond
       [(eq? type 'sub) (emit 'rts)]
       [(eq? type 'vector) (emit 'rti)])
      ; Store inner function calls for building call tree.
      (let ((calls (gvector->list (*invocations*))))
        (make-func-node! name args calls)))))

(define (process-set-bang target expr)
  (assert target syntax?)
  (assert expr syntax?)
  (let* ((lhs (syntax->datum target))
         (rhs (process-argument expr #:atom (lambda (n) (emit 'lda n)))))
    ; TODO: Assert that place is a valid lvalue for set!
    (emit 'sta (as-arg lhs))))

(define (process-instruction-expression instr args)
  (assert instr symbol?)
  (assert args list?)
  (let ((first (resolve-ref args 0))
        (second (resolve-ref args 1))
        (third (resolve-ref args 2)))
    (cond
     ; Single argument to instruction just outputs the instruction.
     ([= (length args) 1]
      (begin
        (assert first atom?)
        (emit instr (as-arg first))))
     ; Single argument with an index register.
     ([and (= (length args) 2) (index-register? second)]
      (begin
        (assert first atom?)
        (emit instr (format "~a,~a" (as-arg first) (->register second)))))
     ; Two arguments, evaluate any expressions, load the first arg into A,
     ; and output the instruction using the second arg as the operand.
     ([= (length args) 2]
      (begin
        (let* ((lhs (process-argument (car args)
                                      #:atom (lambda (n) (emit 'lda n))))
               (rhs (process-argument (cadr args) #:preserve '(a))))
          (emit instr (as-arg rhs)))))
     ; Three arguments. Only works for ORA currently.
     ; TODO: Generalize to other instructions.
     ([= (length args) 3]
      (begin
        (assert instr (lambda (n) (eq? n 'ora)))
        (assert first atom?)
        (assert second atom?)
        (assert third atom?)
        (emit 'lda (as-arg first))
        (emit instr (format "~a|~a" (as-arg second) (as-arg third)))))
     (else (error (format "ERROR expression: ~a ~a" instr args))))))

(define (process-instruction-accumulator instr context-arg)
  (assert instr symbol?)
  (assert context-arg syntax?)
  (emit instr (process-argument context-arg)))

(define (index-register? arg)
  (and (list? arg) (eq? (car arg) 'quote)
       (or (eq? (cadr arg) 'x) (eq? (cadr arg) 'y))))

(define (->register arg)
  (symbol->string (cadr arg)))

(define (resolve-ref list index)
  (if (>= index (length list))
      #f
      (syntax->datum (list-ref list index))))

(define (as-arg arg)
  (cond
   ([string? arg] arg)
   ([symbol? arg] (let ((lookup (sym-label-lookup arg)))
                    (if (not lookup)
                        ; TODO: Throw an error, use syntax object
                        (format "\"not found ~a\"" arg)
                        (if (eq? (sym-label-kind lookup) 'const)
                            (format "#~a" (sym-label-name lookup))
                            (sym-label-name lookup)))))
   ([number? arg] (format "#$~x" arg))
   (else (error (format "ERROR as-arg: ~a" arg)))))

;Generate code to get a single value into the desired return value. Return
; the name of the value.
(define (process-argument context-arg #:preserve [preserve #f] #:atom [atom #f])
  (parameterize ([*co2-source-form* context-arg])
    (let ((arg (syntax->datum context-arg)))
      (when (not atom)
            (set! atom (lambda (n) n)))
      (if (list? arg)
          (begin (emit-context)
                 (when preserve
                       (process-stack 'push preserve #:skip-context #t))
                 (process-form context-arg)
                 (if preserve
                     (begin (emit 'sta "_tmp")
                            (process-stack 'pull preserve #:skip-context #t)
                            "_tmp")
                     "a"))
          (atom (as-arg arg))))))

(define (process-instruction-standalone instr operand)
  ;TODO: Rhs being an expression is an error
  (assert instr symbol?)
  (assert operand syntax?)
  (let ((value (syntax->datum operand)))
    (emit-context)
    (cond
     ([symbol? value] (emit instr (normalize-name value)))
     (else (error (format "ERROR standalone: ~a" value))))))

(define (process-instruction-branch instr target)
  (assert instr symbol?)
  (assert target syntax?)
  (let ((value (syntax->datum target)))
    (assert value symbol?)
    (emit-context)
    (emit instr (cadr (assoc value (lexical-scope))))))

(define (process-instruction-implied instr)
  (assert instr symbol?)
  (emit-context)
  (emit instr))

; TODO: Combine with sym-label-defs.
(define lexical-scope (make-parameter '()))

(define (process-block context-label body)
  (assert context-label syntax?)
  (assert body list?)
  (let* ((label (syntax->datum context-label))
         (gen-label (generate-label (symbol->string label))))
    (emit-label gen-label)
    (parameterize ([lexical-scope (cons (list label gen-label)
                                        (lexical-scope))])
      (for ([stmt body])
           (process-form stmt)))))

(define (process-loop-down context-reg context-start body)
  (assert context-reg syntax?)
  (assert context-start syntax?)
  (assert body list?)
  (emit-context)
  (let ((reg (syntax->datum context-reg))
        (start (syntax->datum context-start))
        (initial-loop-value #f))
    (cond
     ([= start 0] (error "Cannot start loop at 0"))
     ([< start #x100] (set! initial-loop-value start))
     ([= start #x100] (set! initial-loop-value 0))
     (else (error "Initial loop value invalid")))
    (emit (format "  ld~a #~a" reg initial-loop-value))
    (let ((loop-label (generate-label "loop_down_from")))
      (emit-label loop-label)
      ; TODO: Disallow `reg` changes within `body`
      (for ([stmt body])
           (process-form stmt))
      (emit (format "  de~a" reg))
      (emit 'bne loop-label))))

(define (process-loop-up context-reg context-start context-end body)
  (assert context-reg syntax?)
  (assert context-start syntax?)
  (assert context-end syntax?)
  (assert body list?)
  (emit-context)
  (let* ((reg (syntax->datum context-reg))
         (start (syntax->datum context-start))
         ; TODO: Assuming end is a list like (length const-static-array).
         (end (syntax->datum context-end))
         (initial-loop-value start)
         ; TODO: Value reserved by implemention. Ensure `body` doesn't modify it
         (sentinal-value "_count"))
    (when (not (= initial-loop-value 0))
          (error "Start must be 0, other values not supported yet"))
    (emit 'lda (format "#~a_~a"
                       (normalize-name (cadr end)) (normalize-name (car end))))
    (emit 'sta sentinal-value)
    (emit (format "  ld~a #~a" reg initial-loop-value))
    (let ((loop-label (generate-label "loop_up_to")))
      (emit-label loop-label)
      ; TODO: Disallow `reg` changes within `body`
      (for ([stmt body])
           (process-form stmt))
      (emit (format "  in~a" reg))
      (emit (format "  cp~a ~a" reg sentinal-value))
      (emit 'bne loop-label))))

(define (process-let context-bindings body)
  ; TODO: This c(a|d)*r calls are awful.
  (let* ((bindings (syntax->datum context-bindings))
         (label (caar bindings))
         (value (cadr (cadar bindings))))
    (make-data! label value)
    (for ([stmt body])
         (process-form stmt))))

(define (process-if context-condition context-truth context-false)
  (let ((truth-label (generate-label "truth_case"))
        (false-label (generate-label "false_case"))
        (if-done-label (generate-label "if_done")))
    (emit "; condition begin")
    ; Check the condition of the `if`.
    (process-argument context-condition #:atom (lambda (n)
                                                 (error "TODO: Implement me")))
    (emit 'bne false-label)
    ; Truth case of the `if`.
    (emit-label truth-label)
    (process-argument context-truth #:atom (lambda (n) (emit 'lda n)))
    (emit 'jmp if-done-label)
    ; False case of the `if`.
    (emit-label false-label)
    (process-argument context-false #:atom (lambda (n) (emit 'lda n)))
    (emit-label if-done-label)
    (emit "; condition done")))

(define (process-math operator context-left context-right)
  (assert operator symbol?)
  (assert context-left syntax?)
  (assert context-right syntax?)
  (emit-context)
  (let* ((lhs (process-argument context-left
                                #:atom (lambda (n) (emit 'lda n))))
         (rhs (process-argument context-right #:preserve '(a))))
    (case operator
      [(+) (begin (emit 'clc)
                  (emit 'adc (as-arg rhs)))]
      [(eq?) (begin (emit 'sec)
                    (emit 'sbc (as-arg rhs))
                    (emit 'cmp "#1")
                    (emit 'rol "a")
                    (emit 'and "#$fe"))])))

(define (process-stack action registers #:skip-context [skip-context #f])
  (assert action symbol?)
  (assert registers list?)
  (when (not skip-context)
        (emit-context))
  (cond
   [(eq? action 'push) (begin (when (member 'a registers)
                                    (emit 'pha))
                              (when (member 'x registers)
                                    (emit 'txa)
                                    (emit 'pha))
                              (when (member 'y registers)
                                    (emit 'tya)
                                    (emit 'pha)))]
   [(eq? action 'pull) (begin (when (member 'y registers)
                                    (emit 'pla)
                                    (emit 'tay))
                              (when (member 'x registers)
                                    (emit 'pla)
                                    (emit 'tax))
                              (when (member 'a registers)
                                    (emit 'pla)))]))

(define (process-jump-subroutine fname params)
  (let* ((pop-count 0))
    (emit-context)
    (when (> (length params) 3)
          (for ([elem (reverse (cdddr params))])
               (let ((data (syntax->datum elem)))
                 (set! pop-count (+ 1 pop-count))
                 ; TODO: Broken for expressions.
                 (emit 'lda (as-arg data))
                 (emit 'pha))))
    (for ([elem params] [i (in-naturals)])
         (cond
          ([= i 0]
           (process-argument elem #:atom (lambda (n) (emit 'lda n))))
          ([= i 1]
           (emit 'ldx (process-argument elem #:preserve '(a))))
          ([= i 2]
           (emit 'ldy (process-argument elem #:preserve '(a x))))))
    (emit 'jsr (normalize-name fname))
    (for ([i (in-range pop-count)])
         (emit 'pla))
    (gvector-add! (*invocations*) fname)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Syntax tree walker

(define (process-keys args allowed-keywords)
  (for/list ([k allowed-keywords])
    (find-keyword k (map syntax->datum args))))

(define (unwrap-args args num-required num-optional)
  ; TODO: Implement num-required and num-optional
  (map syntax-e args))

(define (process-form form)
  (assert form syntax?)
  (let* ((inner (syntax-e form))
         (first (car inner))
         (rest (cdr inner))
         (symbol (syntax->datum first)))
    (parameterize ([*co2-source-form* form])
      (if (function? symbol)
          (process-jump-subroutine symbol rest)
          (case symbol
            ; Main expression walker.
            [(nes-header) (apply built-in-nes-header
                                 (process-keys rest '(#:num-prg #:num-chr
                                                      #:mapper #:mirroring)))]
            [(init-system) (built-in-init-system)]
            [(defconst) (apply process-defconst (unwrap-args rest 2 0))]
            [(defvar) (apply process-defvar (unwrap-args rest 1 1))]
            [(defsub) (process-proc 'sub (car rest) (cdr rest))]
            [(defvector) (process-proc 'vector (car rest) (cdr rest))]
            [(push pull) (process-stack symbol (unwrap-args rest 0 3))]
            [(set!) (process-set-bang (car rest) (cadr rest))]
            [(block) (process-block (car rest) (cdr rest))]
            [(loop-down-from) (process-loop-down (car rest) (cadr rest)
                                                 (cddr rest))]
            [(loop-up-to) (process-loop-up (car rest) (cadr rest)
                                           (caddr rest) (cdddr rest))]
            [(let) (process-let (car rest) (cdr rest))]
            [(if) (process-if (car rest) (cadr rest) (caddr rest))]
            [(adc and cmp cpx cpy eor lda ora sta)
             (process-instruction-expression symbol rest)]
            [(asl lsr rol ror)
             (process-instruction-accumulator symbol (car rest))]
            [(bit dec inc)
             (process-instruction-standalone symbol (car rest))]
            [(beq bne jmp)
             (process-instruction-branch symbol (car rest))]
            [(clc)
             (process-instruction-implied symbol)]
            [(+ eq?)
             (process-math symbol
                           (car rest)
                           (if (not (null? (cdr rest)))
                               (cadr rest) '()))]
            [else (printf "Unknown: ~a ~a" symbol rest)])))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (resolve-func-node-memory func-nodes n)
  (let* ((f (hash-ref func-nodes n))
         (name (func-node-name f))
         (params (func-node-params f))
         (calls (func-node-calls f))
         (memory (func-node-memory f)))
    (if (number? memory)
        memory ; return early
        (begin (let ((total 0)
                     (curr 0))
                 (for ([c calls])
                   (set! curr (resolve-func-node-memory func-nodes c))
                   (when (> curr total)
                     (set! total curr)))
                 (set! total (+ total (length params)))
                 (set-func-node-memory! f total)
                 total)))))

(define (traverse-func-nodes)
  (let ((names (hash-keys func-nodes)))
    (for ([n names])
      (resolve-func-node-memory func-nodes n))))

(define (process-func-arg-memory-addresses)
  (emit "") (emit "")
  (let ((names (hash-keys func-nodes)))
    (for ([n names])
         (let* ((f (hash-ref func-nodes n))
                (name (func-node-name f))
                (params (func-node-params f))
                (calls (func-node-calls f))
                (memory (func-node-memory f))
                (k (- memory (length params))))
           (for ([p params] [i (in-naturals)])
                (emit (format "_~a__~a = $~x" (normalize-name name)
                              (normalize-name p) (+ k i #x40))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Entry point

; source symbol, assembly label, address / const

(define (define-built-ins)
  ;; Memory-mapped addresses
  (for ([elem reg-table])
       (let ((symbol (car elem))
             (value (cadr elem)))
         (make-address! symbol value)))
  ;; PPU flags
  (for ([elem ppu-flags])
       (let ((symbol (car elem))
             (value (cadr elem)))
         (make-const! symbol value)))
  ;; Reserved zeropage variables for internal use
  (for ([elem reserved-zero-page])
       (let ((symbol (car elem))
             (value (cadr elem)))
         (make-address! symbol value))))

(define (output-prefix)
  ;; Memory-mapped addresses
  (for ([elem reg-table])
       (let ((symbol (car elem))
             (value (cadr elem)))
         (emit (format "~a = $~x" (normalize-name symbol) value))))
  ;; PPU flags
  (for ([elem ppu-flags])
       (let ((symbol (car elem))
             (value (cadr elem)))
         (emit (format "~a = $~x" (normalize-name symbol) value))))
  ;; Reserved zeropage variables for internal use
  (for ([elem reserved-zero-page])
       (let ((symbol (car elem))
             (value (cadr elem)))
         (emit (format "~a = $~x" (normalize-name symbol) value))))
  (emit ""))

(define (output-suffix)
  (emit "") (emit "")
  (let ((data (get-data-segment)))
    (for/list ([elem data])
      (let ((label (car elem))
            (value (cadr elem)))
        (emit (format "~a:" label))
        (emit (format "  .byte ~a" (list->byte-string value)))
        (emit (format "~a_length = ~a" label (length value)))
        (emit ""))))
  (emit ".pad $fffa")
  ; Output the vectors, entry points defined by hardware.
  (let ((build '()))
    (for ([entry '(irq reset nmi)])
         (if (member entry *entry-points*)
             (set! build (cons (symbol->string entry) build))
             (set! build (cons "0" build))))
    (emit (string-append ".word " (string-join build ",")))))

(define (process-co2 fname out-filename f)
  (define-built-ins)
  (output-prefix)
  (define (loop)
    (let ((top-level-form (read-syntax fname f)))
      (when (not (eof-object? top-level-form))
            (process-form top-level-form)
            (loop))))
  (loop)
  (output-suffix))

(let* ((fname (command-line #:args (input) input))
       (f (open-input-file fname)))
  (port-count-lines! f)
  (process-co2 fname "out.asm" f)
  (close-input-port f)
  (traverse-func-nodes)
  (process-func-arg-memory-addresses)
  (for ([line *result*])
       (printf "~a\n" line)))

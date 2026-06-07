.section .text.init
.globl _start

_start:
    li sp, 0x80010000

    li t0, 0          # loop counter
    li t1, 300000     # iterations
    li s0, 0x1234     # pseudo history state

loop:

    # Branch pattern 1
    andi t2, s0, 1
    beq t2, zero, branch1_nt

branch1_t:
    addi s1, s1, 3
    j branch1_done

branch1_nt:
    addi s1, s1, -1

branch1_done:

    # Branch pattern 2
    srli t3, s0, 3
    andi t3, t3, 1
    bne t3, zero, branch2_t

branch2_nt:
    addi s1, s1, -2
    j branch2_done

branch2_t:
    addi s1, s1, 5

branch2_done:

    # Branch pattern 3
    xor t4, s0, t0
    andi t4, t4, 1
    beq t4, zero, branch3_nt

branch3_t:
    addi s1, s1, 7
    j branch3_done

branch3_nt:
    addi s1, s1, -3

branch3_done:

    # Update pseudo-history
    slli s0, s0, 1
    xor s0, s0, t0
    xori s0, s0, 0x9

    addi t0, t0, 1

    blt t0, t1, loop

hang:
    j hang
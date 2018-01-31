# GDB commands for use with GuardRails.
# (gdb) source grgdb.py

import gdb
import gdb.printing
import re

PAGE_SIZE = 4096
NUM_GUARD_PAGES = 1
GUARD_SIZE = NUM_GUARD_PAGES * PAGE_SIZE
MAGIC_FREE = 0xcd656727bedabb1e
MAGIC_INUSE = 0x4ef9e433f005ba11

class GRFindDelayList (gdb.Command):
    """ Search Guard Rails delayed free list for a given address.

        (gdb) gr-find-delay-list <delayListAddress> <addressToFind>

        Example:
        (gdb) gr-find-delay-list &memSlots[0].delay 0x7f607e24dbf0
    """

    def __init__ (self):
        super (GRFindDelayList, self).__init__ ("gr-find-delay-list", gdb.COMMAND_USER)

    def delayListCount(self, head, tail, maxDelayCt):
        if head > tail:
            return head - tail
        else:
            return maxDelayCt - (tail - head)

    def invokeHelper (self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        if len(argv) != 2:
            print("Malformed arguments; see help")
            return

        dlist = gdb.parse_and_eval('(MemFreeDelay *) ' + argv[0])
        addrToFind = int(argv[1], 16)
        dlistElms = dlist['elms']
        maxDelayCt = int(gdb.parse_and_eval('sizeof(((MemFreeDelay *)0x0)->elms)/sizeof(((MemFreeDelay *)0x0)->elms[0])'))
        head = dlist['head']
        tail = dlist['tail']
        cursor = head
        delayCount = self.delayListCount(head, tail, maxDelayCt)
        ct = 0
        while ct < delayCount:
            if not ct % 1000:
                print("Searching %7d / %d elements" % (ct, delayCount))
            elmPtr = dlistElms[cursor]
            elm = elmPtr.dereference()

            magicStr = str(elm['magic'])
            if elm['magic'] != MAGIC_FREE:
                print("Delayed free list contains invalid header magic 0x%x" % magicStr)

            elmStartAddr = int(elmPtr)

            # Consider the full allocation (not just the amount allocated for the
            # user), as the errant pointer might land anywhere in that range.
            elmEndAddr = elmStartAddr + (1 << int(elm['binNum'])) + GUARD_SIZE - 1

            if elmStartAddr <= addrToFind <= elmEndAddr:
                print("Found address 0x%x on delayed free list at index %d, header 0x%x :" % (addrToFind, cursor, elmPtr))
                # print("%x <= %x <= %x" % (elmStartAddr, addrToFind, elmEndAddr))
                print(elm)
                # An element should only appear on the list once, so return
                return

            # Search the list from the head (most recently added) backwards as
            # the element of interest is most likely recent (and search can be
            # somewhat slow)
            if cursor == 0:
                cursor = maxDelayCt
            cursor -= 1

            ct += 1

        print("Address 0x%x not found" % (addrToFind))


    def invoke(self, arg, from_tty):
        try:
            self.invokeHelper(arg, from_tty)
        except Exception as e:
            print(str(e))
            traceback.print_exc()

class GRPrintAddrInfo (gdb.Command):
    """ Try to print GuardRails info about an address.

        The address must be either the beginning of a header or beginning of a
        user allocation.  If the address is unknown first try to find it on
        the delay list with find-delay-list.

        allocFrameDepth and freeFrameDepth correspond to the -t <depth> and
        -T <depth> guardrails arguments respectively.  If tracking was not
        enabled during the run use zero.

        (gdb) gr-print-addr-info <address> <allocFrameDepth> <freeFrameDepth>

        Example:
        (gdb) gr-print-addr-info 0x7fc6aa5f2000 30 30
    """

    def __init__ (self):
        super (GRPrintAddrInfo, self).__init__ ("gr-print-addr-info", gdb.COMMAND_USER)

    def isValid(self, magic):
        return magic == MAGIC_INUSE or magic == MAGIC_FREE

    def dumpSymTrace(self, trace, offset, maxFrames):
        for i in range(offset, maxFrames + offset):
            addrInt = int(trace[i])
            if not addrInt:
                continue
            sym = str(gdb.execute('info line *' + str(addrInt), to_string=True))
            sym = re.sub(r' and ends at .*', r'', sym)
            print(sym[0:-1])

    def invokeHelper(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        if len(argv) != 3:
            print("Malformed arguments; see help")
            return

        hdrPtr = gdb.parse_and_eval('(ElmHdr *) ' + argv[0])
        hdr = hdrPtr.dereference()
        maxAllocFrames = int(argv[1])
        maxFreeFrames = int(argv[2])

        if self.isValid(hdr['magic']):
            print("Address %s is a header" % argv[0])
        else:
            hdrPtr = gdb.parse_and_eval('*(ElmHdr **)((char *)' + argv[0] + ' - sizeof(void *))')
            hdr = hdrPtr.dereference()
            if self.isValid(hdr['magic']):
                print("Address %s is a user address" % argv[0])
            else:
                print("Address %s doesn't look valid" % argv[0])
                return

        print("Header:")
        print(hdr)

        trace = hdr['allocBt']

        print("================ Allocation Trace: ================")
        self.dumpSymTrace(trace, 0, maxAllocFrames)
        print("================ Free Trace: ================")
        self.dumpSymTrace(trace, maxAllocFrames + 1, maxFreeFrames)

    def invoke(self, arg, from_tty):
        try:
            self.invokeHelper(arg, from_tty)
        except Exception as e:
            print(str(e))
            traceback.print_exc()

GRFindDelayList()
GRPrintAddrInfo()

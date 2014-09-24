linux-memavailable-procfs
=========================

A Perl port of the /proc/meminfo "MemAvailable" metric which got introduced in Linux 3.14 kernels.

Additionally, an improved "free" util is provided which replaces the traditional, outdated one.

You can read the Perl module documentation by executing "perldoc Linux-MemAvailable.pm" in a terminal.
The "free.pl" executable has a standard documentation via "--help".

The original C source code in the kernel:
https://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/commit/?id=34e431b0ae398fc54ea69ff85ec700722c9da773

More info about the "MemAvailable" metric can be found in the kernel /proc filesystem docs:
https://www.kernel.org/doc/Documentation/filesystems/proc.txt

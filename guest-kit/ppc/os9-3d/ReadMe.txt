Mac OS 9 3D (OpenGL) for UTM
============================

OpenGLLibrary replaces Apple's OpenGLLibrary so OpenGL games run on the
host GPU. It needs a UTM VM with the "VGA" display (Mac OS 9, mac99) and
this UTM version's qemu_vga driver. Tested with GLQuake.

Install
1. Open your System Folder, then the Extensions folder.
2. Find Apple's "OpenGLLibrary". Drag it into the folder
   "Extensions (Disabled)" (create that folder in the System Folder
   if it does not exist).
3. Drag the OpenGLLibrary from this folder into Extensions.
4. Restart the Mac.

Use
- Run one OpenGL program at a time. Quit it before opening another.
- Full screen and windowed modes work. If something goes wrong, the
  file OpenGLLibrary.log appears next to the program.

Uninstall
- Move OpenGLLibrary out of Extensions, put Apple's back, restart.

If OpenGLLibrary looks like a plain document, use OpenGLLibrary.bin
instead and expand it with StuffIt Expander.

Mac OS 9 3D (OpenGL and RAVE) for UTM
=====================================

OpenGLLibrary replaces Apple's OpenGLLibrary so OpenGL games run on the
host GPU. "UTM RAVE Loader" turns on Apple's Classic RAVE engine on top of
that OpenGL, so RAVE and QuickDraw 3D games are accelerated too. Both need
a UTM VM with the "VGA" display (Mac OS 9, mac99) and this UTM version's
qemu_vga driver. Tested with GLQuake, Quake III Arena demo, Nanosaur and
Blokz RAVE.

Install
1. Open your System Folder, then the Extensions folder.
2. Find Apple's "OpenGLLibrary". Drag it into the folder
   "Extensions (Disabled)" (create that folder in the System Folder
   if it does not exist).
3. Drag OpenGLLibrary and UTM RAVE Loader from this folder into
   Extensions.
4. Restart the Mac.

Apple's own files (Classic RAVE, QuickDraw 3D RAVE, OpenGLUtility) stay as
they are; nothing of Apple's is modified.

Use
- Several OpenGL programs can run at the same time; windows in front of
  an OpenGL window are respected.
- Full screen and windowed modes work.
- RAVE games use the "RAVEOGL" engine; Apple's software RAVE engine is
  switched off while the loader is installed.
- Diagnostics: an empty file named "OpenGLLibrary.debug" in the System
  Folder writes a detailed OpenGLLibrary.log there. Remove it afterwards.

Uninstall
- Move OpenGLLibrary and UTM RAVE Loader out of Extensions, put Apple's
  OpenGLLibrary back, restart.

If a file looks like a plain document, use the .bin copy instead and
expand it with StuffIt Expander.

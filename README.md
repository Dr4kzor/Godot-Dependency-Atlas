# Godot-Orphan-Finder
# Disclamer this was all coded acording to my prompts with claude AI with some manual fixes 


## Created Addon to search orphan files leftover in Godot projects
![OrphanFileFinder](screenshot/Screenshot.png)
We do a tree traversal starting from main scene and so on... addons and autoloaded scripts should be also acounted for and fully explored.
Double clicking on the files shown will show them on the editor
This also genereates a log file with all orphans found


![OrphanFileFinder_Icon](Icon.png)


## Language support

The reachability graph understands Godot resources plus GDScript, C#, and GDExtension C/C++ source:

- C# class/struct/interface declarations, inheritance, type usage, project/solution files, and SDK-style implicit compile membership.
- C/C++ quoted and system includes, class/struct inheritance, type usage, and common source/header extensions.
- `CMakeLists.txt`, SCons, Meson, Visual Studio, C# project, and solution build manifests, including explicit source names and extension globs.
- Build membership is kept distinct from runtime, inheritance, include, and type-use edges in the graph.

The analysis is conservative. Generated source, preprocessor-selected files, reflection, P/Invoke, dynamic libraries, and paths assembled at runtime cannot always be proven statically. Always inspect the reported reference graph before deleting a native or managed file.

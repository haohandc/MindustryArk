package probe;

import mindustry.mod.Mod;

/**
 * The smallest mod that can PROVE the loader works.
 *
 * WHY THIS EXISTS
 *   Mindustry's mod support has never run on this platform, and the open
 *   question is narrow: can a class loaded at runtime out of a mod jar be
 *   defined and executed under this JVM? Everything else about mods -- the
 *   directory scan, the content parser, the lifecycle -- is stock Mindustry.
 *
 * WHY IT LOGS INSTEAD OF ADDING CONTENT
 *   This project already has a rule about exactly this: "it appears in the mod
 *   list" is NOT the same as "it actually took effect". A log line cannot be
 *   produced by anything except this class body executing, so it proves BOTH
 *   that the class was defined AND that its lifecycle methods were called.
 *   A mod that merely shows up in a list proves neither.
 *
 *   The two markers are deliberately distinct so a partial result is still
 *   informative: init() runs before content loading, loadContent() during it.
 *   Seeing only the first would mean class loading works but the content phase
 *   does not.
 *
 * Pure ASCII on purpose: this project has been bitten twice by clang decoding
 * a source file as GBK on a Chinese Windows console. javac is not clang, but
 * there is no reason to find out the hard way.
 */
public class ProbeMod extends Mod {

    @Override
    public void init() {
        System.out.println("[probe-mod] MARKER-INIT-RAN");
    }

    @Override
    public void loadContent() {
        System.out.println("[probe-mod] MARKER-LOADCONTENT-RAN");
    }
}

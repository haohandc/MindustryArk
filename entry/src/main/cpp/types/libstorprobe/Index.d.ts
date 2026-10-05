/* 存储位置探针。见 cpp/storprobe.c 的文件头。
 *
 * ⛔ **判据只有 `ok` 开头那一种**，其余全是「不能切过去」。返回值是字符串不是布尔，
 *    因为「目录不存在」「没权限」「写了读不回来」「写着但收不干净」是四种不同处境。 */
export const probeWritable: (dir: string) => string;

/* 递归复制一棵树（搬「存储位置」用）。⛔ **故意放在 native** —— 见 cpp/storprobe.c 里
 * `copyTree` 上方那段：同一个文件、同一个外部路径，ArkTS 的 `copyFileSync` 报 EPERM，
 * 而 native 的裸 POSIX 拷贝成功。不做解释，走被证明的那条路。
 * 返回 `ok: N files, M dirs` 或 `fail N: <第一条错误，带源与目标路径>`。 */
export const copyTree: (src: string, dst: string) => string;

/* 列一棵树的清单（**每行带文件大小**），诊断用。
 * ⛔ 它存在的理由：外置那个文件夹 **ArkTS 侧不一定读得到、hdc 连 `/storage/Users` 都看不见**
 *    ⇒ 不靠它，那棵树在排查里就是不存在的（2026-10-04 为这个盲区返工过）。
 * 返回 `absent: errno=N …` / `not-a-dir` / 若干行（截断会写明）。 */
export const listTree: (dir: string, maxDepth?: number) => string;

/* 路径**存在**吗（`lstat`）。1 = 存在，0 = 不存在。
 * ⭐ 它比 `listTree` 便宜得多（一次 stat，而不是列一棵树），所以「判存在」用它。
 * ⛔ 与 ArkTS 的 `fs.accessSync` 不是重复品：那个在外部根上实测会误报。 */
export const pathExists: (path: string) => number;

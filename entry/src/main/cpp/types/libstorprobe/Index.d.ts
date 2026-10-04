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

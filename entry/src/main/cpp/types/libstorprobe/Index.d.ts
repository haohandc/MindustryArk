/* 存储位置探针。见 cpp/storprobe.c 的文件头。
 *
 * ⛔ **判据只有 `ok` 开头那一种**，其余全是「不能切过去」。返回值是字符串不是布尔，
 *    因为「目录不存在」「没权限」「写了读不回来」「写着但收不干净」是四种不同处境。 */
export const probeWritable: (dir: string) => string;

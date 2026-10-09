import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { execFileSync } from 'node:child_process';
import * as path from 'node:path';
import { hvigor } from '@ohos/hvigor';

// Python 解释器：先 ARK_PYTHON，再退到 PATH 上的 "python"（与 build.sh / deploy.sh / scripts/config.py 一致）。
// 兜底必须是 "python" 而非 "python3"——本机 python3 是另一个版本。这里原是一条写死的绝对路径（带某用户目录），
// 会让已提交的文件在别的机器上必然错，且报错会指向闸门而非路径；而本文件正是跑产物闸门的地方。
// ⚠️ ARK_PYTHON 实测（2026-09-29）只在 --no-daemon 时可靠：守护进程启动时捕获环境变量，之后从 shell 设的值进不去、被静默忽略并退回 PATH ⇒ 真正兜住换机器的是 PATH 兜底，下面那条日志暴露这种静默取错值。
const PYTHON = process.env.ARK_PYTHON || 'python';

function verifyArtifact() {
  return {
    pluginId: 'mindustryark-verify-artifact',
    apply(node) {
      const assemble = node.getTaskByName('assembleHap');
      if (!assemble) {
        console.error('[ARK] assembleHap not found -- verification gate NOT installed');
        throw new Error('verification gate NOT installed');
      }

      const projectRoot = path.dirname(node.getNodePath());
      const script = path.join(projectRoot, 'scripts', 'verify_hap.py');

      assemble.afterRun(() => {
        const product = hvigor.getParameter().getExtParam('product') ?? 'default';
        // ⭐ `ARK_FORM` 是**构建形态**，不是分支身份（分支身份是 config.py 里那个可提交的布尔）；
        //    只有 `make_store_app.sh tools` 会设它，平常为 'full'。它决定下面闸门断言「JDK 必须在」还是「必须不在」，
        //    两者恰好相反 ⇒ 它一旦没传进来，tools 构建会被自己的闸门打回，且报错指向「缺 JDK 条目」、完全不提环境变量。
        //    ⚠️ 必须打印出来。传递靠下面 `env: { ...process.env }`；同类先例见文件头 ARK_PYTHON（仅 --no-daemon 可靠）。
        const form = process.env.ARK_FORM || 'full';
        console.log(`[ARK] verifying artifact (product=${product}, form=${form}, python=${PYTHON}) ...`);
        try {
          execFileSync(PYTHON, [script], {
            env: { ...process.env, ARK_PRODUCT: product, ARK_FORM: form },
            stdio: 'inherit',
          });
        } catch (e) {
          // ENOENT 说明解释器本身不存在，而不是脚本报了错。
          // 那种情况下抛出去的原始错误只说 "spawn python ENOENT"，
          // 不告诉你该改哪个变量。
          if ((e as { code?: string } | null)?.code === 'ENOENT') {
            console.error(`[ARK] cannot run "${PYTHON}" -- put python on PATH, or set ARK_PYTHON to its full path`);
          }
          throw e;
        }
        console.log('[ARK] verification PASS');
      });

      console.log('[ARK] artifact verification gate attached');
    },
  };
}

export default {
  system: hapTasks,
  plugins: [verifyArtifact()],
};
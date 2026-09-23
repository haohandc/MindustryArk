import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { execFileSync } from 'node:child_process';
import * as path from 'node:path';
import { hvigor } from '@ohos/hvigor';

const PYTHON = 'C:\\Users\\Haohandc\\AppData\\Local\\Programs\\Python\\Python312\\python.exe';

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
        console.log(`[ARK] verifying artifact (product=${product}) ...`);
        execFileSync(PYTHON, [script], {
          env: { ...process.env, ARK_PRODUCT: product },
          stdio: 'inherit',
        });
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
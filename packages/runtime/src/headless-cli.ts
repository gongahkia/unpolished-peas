import { runHeadless } from './headless';

try {
  let source = '';
  for await (const chunk of process.stdin) source += String(chunk);
  const result = await runHeadless(JSON.parse(source) as unknown);
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error: unknown) {
  process.stderr.write(`${error instanceof Error ? error.message : 'headless host failed'}\n`);
  process.exitCode = 1;
}

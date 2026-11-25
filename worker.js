export default {
  async fetch() {
    return new Response("Not Found", { status: 404 });
  },

  async scheduled(controller, env, ctx) {
    if (!env.DEPLOY_HOOK_URL) {
      console.warn("DEPLOY_HOOK_URL is not configured; skipping scheduled rebuild.");
      return;
    }

    ctx.waitUntil(
      (async () => {
        const response = await fetch(env.DEPLOY_HOOK_URL, { method: "POST" });
        if (!response.ok) {
          const text = await response.text();
          throw new Error(`Deploy hook trigger failed (${response.status}): ${text}`);
        }
        console.log(`Triggered scheduled rebuild via deploy hook (${controller.cron}).`);
      })()
    );
  },
};

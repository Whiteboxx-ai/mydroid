import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://mydroid.whiteboxx.ai',
  integrations: [
    starlight({
      title: 'Mydroid',
      description: 'Your Android phone on your Mac. Free, open source, no account.',
      favicon: '/favicon.svg',
      logo: { src: './src/assets/icon.svg' },
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/Whiteboxx-ai/mydroid' }],
      components: { Head: './src/components/GuideHead.astro' },
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://mydroid.whiteboxx.ai/screenshots/mydroid-social.jpg' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'An Android text conversation open in Mydroid for Mac' } },
      ],
      customCss: ['./src/styles.css'],
      sidebar: [
        { label: 'Get started', items: [
          { slug: 'get-started' },
          { slug: 'get-started/install-mac' },
          { slug: 'get-started/install-android' },
          { slug: 'get-started/pair' },
          { slug: 'get-started/walkthrough' },
          { slug: 'get-started/compatibility' },
          { slug: 'get-started/build-from-source' },
        ] },
        { label: 'Features', items: [
          { slug: 'features/notifications' },
          { slug: 'features/messages-and-calls' },
          { slug: 'features/file-transfer' },
          { slug: 'features/photo-sync' },
          { slug: 'features/photos-and-files' },
          { slug: 'features/clipboard-and-links' },
          { slug: 'features/authenticator' },
          { slug: 'features/remote-and-lock' },
        ] },
        { label: 'Help', items: [
          { slug: 'help/troubleshooting' },
          { slug: 'help/keep-it-running' },
          { slug: 'help/update-and-remove' },
          { slug: 'help/faq' },
        ] },
        { slug: 'compare/android-to-mac' },
        { slug: 'privacy' },
      ],
    }),
  ],
});

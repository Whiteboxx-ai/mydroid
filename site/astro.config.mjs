import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://mydroid.app',
  integrations: [
    starlight({
      title: 'Mydroid',
      description: 'Your Android phone on your Mac. Free, open source, no account.',
      favicon: '/favicon.svg',
      logo: { src: './src/assets/icon.svg' },
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/gautamm20/mydroid' }],
      customCss: ['./src/styles.css'],
      sidebar: [
        { label: 'Get started', items: [
          { slug: 'get-started/install-mac' },
          { slug: 'get-started/install-android' },
          { slug: 'get-started/pair' },
        ] },
        { label: 'Features', items: [
          { slug: 'features/messages-and-calls' },
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
        { slug: 'privacy' },
      ],
    }),
  ],
});

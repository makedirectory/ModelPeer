// @ts-check
import {themes as prismThemes} from 'prism-react-renderer';

const ORG = 'makedirectory';
const REPO = 'ModelPeer';
// Custom domain. GitHub Pages learns it from static/CNAME, which Docusaurus
// copies verbatim into the build output; url/baseUrl must agree with it or every
// generated absolute link and the sitemap point at the wrong host.
const SITE_URL = 'https://modelpeer.app';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Model Peer',
  tagline: 'Cross-model peer review for coding agents',
  favicon: 'img/favicon.svg',

  url: SITE_URL,
  baseUrl: '/',
  organizationName: ORG,
  projectName: REPO,
  trailingSlash: false,

  // A broken link is a docs bug; fail the build rather than ship one.
  onBrokenLinks: 'throw',
  onBrokenAnchors: 'throw',
  markdown: {
    hooks: {onBrokenMarkdownLinks: 'throw'},
  },

  i18n: {defaultLocale: 'en', locales: ['en']},

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: './sidebars.js',
          routeBasePath: '/',
          editUrl: `https://github.com/${ORG}/${REPO}/tree/main/documentation/`,
        },
        blog: false,
        theme: {customCss: './src/css/custom.css'},
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      colorMode: {respectPrefersColorScheme: true},
      navbar: {
        title: 'Model Peer',
        items: [
          {type: 'docSidebar', sidebarId: 'docs', position: 'left', label: 'Docs'},
          {
            href: `https://github.com/${ORG}/${REPO}/releases`,
            label: 'Releases',
            position: 'right',
          },
          {
            href: `https://github.com/${ORG}/${REPO}`,
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              {label: 'Introduction', to: '/'},
              {label: 'Install', to: '/install'},
              {label: 'Peer-chain depth', to: '/depth'},
              {label: 'Safety boundaries', to: '/safety'},
            ],
          },
          {
            title: 'Project',
            items: [
              {label: 'GitHub', href: `https://github.com/${ORG}/${REPO}`},
              {label: 'Releases', href: `https://github.com/${ORG}/${REPO}/releases`},
              {label: 'Discussions', href: `https://github.com/${ORG}/${REPO}/discussions`},
              {label: 'Security', href: `https://github.com/${ORG}/${REPO}/security`},
            ],
          },
          {
            title: 'Vendor CLIs',
            items: [
              {label: 'Claude Code', href: 'https://code.claude.com/docs/en/cli-reference'},
              {label: 'OpenAI Codex CLI', href: 'https://developers.openai.com/codex/cli'},
              {label: 'Gemini CLI', href: 'https://google-gemini.github.io/gemini-cli/docs/'},
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Make Directory Developers, LLC. MIT licensed.<br/>Model Peer is an independent project, not affiliated with or endorsed by Anthropic, OpenAI, or Google.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['bash', 'toml', 'json'],
      },
    }),
};

export default config;

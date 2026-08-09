// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'Getting started',
      collapsed: false,
      items: ['install', 'usage', 'agent-rules'],
    },
    {
      type: 'category',
      label: 'How it works',
      collapsed: false,
      items: ['depth', 'safety'],
    },
    {
      type: 'category',
      label: 'Reference',
      collapsed: false,
      items: ['reference', 'development'],
    },
    'roadmap',
  ],
};

export default sidebars;

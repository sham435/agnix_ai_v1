module.exports = {
  content: [
    './app/helpers/**/*.rb',
    './app/javascript/**/*.js',
    './app/views/**/*.{erb,haml,html,slim}',
    './app/components/**/*.{erb,haml,html,slim,rb}'
  ],
  darkMode: 'class',
  theme: {
    extend: {
      fontFamily: {
        sans: ['Instrument Sans', 'Inter', 'system-ui', 'sans-serif'],
        arabic: ['Noto Sans Arabic', 'Inter', 'sans-serif'],
        mono: ['ui-monospace', 'Cascadia Code', 'SF Mono', 'Menlo', 'Consolas', 'monospace']
      },
      colors: {
        // QoderWork-inspired palette
        sidebar: '#0d0d0d',
        canvas: '#050505',
        panel: '#171716',
        border: '#262626',
        accent: '#5cb870',
        'accent-hover': '#73cd94',
        'accent-text': '#8ee5a1',
        'fill-secondary': '#292926',
        'fill-tertiary': '#1a1a1a',
        'text-secondary': '#9c9d9e',
        'text-tertiary': '#7c7d7f'
      },
      boxShadow: {
        glow: '0 0 40px rgba(92, 184, 112, 0.15)',
        'glow-lg': '0 0 60px rgba(92, 184, 112, 0.2)'
      },
      borderRadius: {
        'xl': '0.75rem',
        '2xl': '1rem',
        '3xl': '1.5rem'
      }
    }
  },
  plugins: []
}

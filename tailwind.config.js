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
        sans: ['Inter', 'system-ui', 'sans-serif'],
        arabic: ['Noto Sans Arabic', 'Inter', 'sans-serif']
      },
      colors: {
        sidebar: '#0f0f12',
        canvas: '#080808',
        panel: '#111113',
        border: '#1f1f23',
        accent: '#ff8a00'
      },
      boxShadow: {
        glow: '0 0 40px rgba(255,138,0,0.15)'
      }
    }
  },
  plugins: []
}

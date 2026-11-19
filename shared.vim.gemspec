Gem::Specification.new do |s|
  s.name             = "shared.vim"
  s.version          = "1.0.0"
  s.platform         = Gem::Platform::RUBY
  s.license          = "GPL-3.0-or-later"
  s.summary          = "shared.vim - Live co-editing in Vim, for everybody on the same computer."

  s.description      = "see https://github.com/etm/shared.vim"

  s.files            = Dir['{plugin/**/*,lib/**/*,tools/**/*,test/**/*}'] + %w(LICENSE Rakefile shared.vim.gemspec README.md AUTHORS)
  s.require_path     = 'lib'
  s.extra_rdoc_files = ['README.md']
  s.bindir           = 'tools'
  s.executables      = ['shared-vim-server', 'shared-vim-install']

  s.required_ruby_version = '>=3.0.0'

  s.authors          = ['Juergen eTM Mangler']

  s.email            = 'juergen.mangler@gmail.com'
  s.homepage         = 'https://github.com/etm/shared.vim'
end

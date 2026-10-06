project('singularity-news', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-news"', language: 'c')
subdir('po')

gtk_dep  = dependency('gtk4')
gee_dep  = dependency('gee-0.8')
soup_dep = dependency('libsoup-3.0')
json_dep = dependency('json-glib-1.0')
xml_dep  = dependency('libxml-2.0')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

gnome = import('gnome')
resources = gnome.compile_resources(
  'singularity-news-resources',
  'resources/dev.sinty.news.gresource.xml',
  source_dir: meson.current_source_dir() / 'data' / 'icons',
)

core_sources = files('src/feed.vala', 'src/html.vala', 'src/discovery.vala', 'src/opml.vala', 'src/store.vala', 'src/fetcher.vala', 'src/extract.vala', 'src/mute.vala', 'src/saved.vala')

executable('singularity-news',
  core_sources + files('src/images.vala', 'src/article_view.vala', 'src/rows.vala', 'src/dialogs.vala', 'src/window.vala', 'src/search.vala', 'src/app.vala') + [resources],
  dependencies: [gtk_dep, gee_dep, soup_dep, json_dep, xml_dep, libsingularity_dep],
  install: true
)

shared_module('singularity-news-widget',
  files('widget/headlines_widget.vala'),
  dependencies: [gtk_dep, gee_dep, json_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)
install_data('widget/dev.sinty.news.headlines.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

news_test = executable('news-test',
  core_sources + files('tests/news_test.vala'),
  dependencies: [gee_dep, soup_dep, json_dep, xml_dep, dependency('gio-2.0')],
)
test('news', news_test, env: ['NEWS_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures'])

install_data('data/dev.sinty.news.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.news.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.news.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.news.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

install_data('data/search-providers/dev.sinty.news.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.news.service.in',
  output: 'dev.sinty.news.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

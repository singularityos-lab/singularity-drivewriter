project('singularity-drivewriter', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-drivewriter"', language: 'c')
subdir('po')

gtk_dep      = dependency('gtk4')
gee_dep      = dependency('gee-0.8')
gio_dep      = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
posix_dep    = meson.get_compiler('vala').find_library('posix')
m_dep        = meson.get_compiler('c').find_library('m', required: false)
lzma_dep     = dependency('liblzma', required: get_option('xz'))
zstd_dep     = dependency('libzstd', required: get_option('zstd'))

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

bridge_args = []
bridge_deps = [dependency('glib-2.0')]
if lzma_dep.found()
  bridge_args += '-DHAVE_LZMA'
  bridge_deps += lzma_dep
endif
if zstd_dep.found()
  bridge_args += '-DHAVE_ZSTD'
  bridge_deps += zstd_dep
endif

bridge = static_library('decoder-bridge', 'src/decoder-bridge.c',
  c_args: bridge_args,
  dependencies: bridge_deps)

bridge_vala_args = ['--vapidir=' + meson.current_source_dir() / 'vapi', '--pkg=decoderbridge']

core_sources = files(
  'src/format.vala',
  'src/image.vala',
  'src/writer.vala',
  'src/udisks.vala',
  'src/checksum.vala',
)

executable('singularity-drivewriter',
  core_sources + files(
    'src/window.vala',
    'src/app.vala',
  ),
  vala_args: bridge_vala_args,
  include_directories: include_directories('src'),
  link_with: bridge,
  dependencies: [gtk_dep, gee_dep, gio_dep, gio_unix_dep, posix_dep, m_dep, libsingularity_dep],
  install: true
)

image_test = executable('drivewriter-test',
  core_sources + files('tests/image_test.vala'),
  vala_args: bridge_vala_args,
  include_directories: include_directories('src'),
  link_with: bridge,
  dependencies: [gee_dep, gio_dep, gio_unix_dep, posix_dep, m_dep],
)
test('image', image_test, env: ['DRIVEWRITER_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures'])

checksum_test = executable('checksum-test',
  core_sources + files('tests/checksum_test.vala'),
  vala_args: bridge_vala_args,
  include_directories: include_directories('src'),
  link_with: bridge,
  dependencies: [gee_dep, gio_dep, gio_unix_dep, posix_dep, m_dep],
)
test('checksum', checksum_test)

install_data('data/dev.sinty.drivewriter.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.drivewriter.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.drivewriter.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/dev.sinty.drivewriter.write.ini',
  install_dir: get_option('datadir') / 'singularity' / 'files-actions'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.drivewriter.service.in',
  output: 'dev.sinty.drivewriter.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/icons/dev.sinty.drivewriter.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

#!/usr/bin/env python
from __future__ import print_function
import os
import shutil
import subprocess
import sys
import contextlib
from distutils.command.build_ext import build_ext
from distutils.sysconfig import get_python_inc
from distutils.ccompiler import get_default_compiler

try:
    from setuptools import Extension, setup
    from pkg_resources import resource_filename
except ImportError:
    from distutils.core import Extension, setup
    def resource_filename(package, _):
        return import_include(package).get_include()


PACKAGES = [
    'sense2vec',
    'sense2vec.tests'
]

MOD_NAMES = [
    'sense2vec.vectors'
]


# By subclassing build_extensions we have the actual compiler that will be used which is really known only after finalize_options
# http://stackoverflow.com/questions/724664/python-distutils-how-to-get-a-compiler-that-is-going-to-be-used
compile_options =  {'msvc'  : ['/Ox', '/EHsc'],
                    'other' : ['-O3',
                               '-Wno-unused-function',
                               '-fno-stack-protector']}
link_options    =  {'msvc'  : [],
                    'other' : ['-fno-stack-protector']}


if sys.platform.startswith('darwin'):
    compile_options['other'].extend([
        '-stdlib=libc++',
        '-mmacosx-version-min=10.7'])
else:
    compile_options['other'].append('-fopenmp')
    link_options['other'].append('-fopenmp')


class build_ext_subclass(build_ext):
    def build_extensions(self):
        # for mod_name in ['numpy', 'murmurhash']:
        #     mod = import_include(mod_name)
        #     if mod:
        #         self.compiler.add_include_dir(resource_filename(
        #             mod_name, os.path.relpath(mod.get_include(), mod.__path__[0])))

        for e in self.extensions:
            e.extra_compile_args.extend(compile_options.get(
                self.compiler.compiler_type, compile_options['other']))
        for e in self.extensions:
            e.extra_link_args.extend(link_options.get(
                self.compiler.compiler_type, link_options['other']))
        build_ext.build_extensions(self)


def generate_cython(root, source):
    print('Cythonizing sources')
    p = subprocess.call([sys.executable,
                         os.path.join(root, 'bin', 'cythonize.py'),
                         source])
    if p != 0:
        raise RuntimeError('Running cythonize failed')


def import_include(module_name):
    try:
        return __import__(module_name, globals(), locals(), [], 0)
    except ImportError:
        pass


def is_source_release(path):
    return os.path.exists(os.path.join(path, 'PKG-INFO'))


def clean(path):
    for name in MOD_NAMES:
        name = name.replace('.', '/')
        for ext in ['.so', '.html', '.cpp', '.c']:
            file_path = os.path.join(path, name + ext)
            if os.path.exists(file_path):
                os.unlink(file_path)


@contextlib.contextmanager
def chdir(new_dir):
    old_dir = os.getcwd()
    try:
        os.chdir(new_dir)
        sys.path.insert(0, new_dir)
        yield
    finally:
        del sys.path[0]
        os.chdir(old_dir)


def setup_package():
    root = os.path.abspath(os.path.dirname(__file__))
    src_path = 'sense2vec'

    if len(sys.argv) > 1 and sys.argv[1] == 'clean':
        return clean(root)

    with chdir(root):
        with open(os.path.join(root, src_path, 'about.py')) as f:
            about = {}
            exec(f.read(), about)

        with open(os.path.join(root, 'README.rst')) as f:
            readme = f.read()

        with open(os.path.join(root, 'sense2vec', 'cpuinfo.py')) as f:
            cpuinfo = {}
            exec(f.read(), cpuinfo)

        with open(os.path.join(root, 'sense2vec', 'arch.py')) as f:
            arch = {}
            exec(f.read(), arch)

        include_dirs = [
            get_python_inc(plat_specific=True),
            os.path.join(root, 'include')]

        ext_modules = []
        for mod_name in MOD_NAMES:
            mod_path = mod_name.replace('.', '/') + '.cpp'

            flags = cpuinfo['get_cpu_info']()['flags']
            supported_archs = arch['get_supported_mapping'](flags)

            for flag, (define, option) in supported_archs.items():
                ext_args = {
                    'language':'c++',
                    'include_dirs': include_dirs}
                if define:
                    ext_args['define_macros'] = [(define, None)]
                if option and get_default_compiler() == 'unix':
                    ext_args['extra_compile_args'] = [option]

                ext_modules.append(
                    Extension(mod_name, [mod_path], **ext_args))

        if not is_source_release(root):
            generate_cython(root, src_path)

        setup(
            name=about['__title__'],
            zip_safe=False,
            packages=PACKAGES,
            package_data={'': ['*.pyx', '*.pxd', '*.pxi']},
            description=about['__summary__'],
            long_description=readme,
            author=about['__author__'],
            author_email=about['__email__'],
            version=about['__version__'],
            url=about['__uri__'],
            license=about['__license__'],
            ext_modules=ext_modules,
            install_requires=[
                'numpy<1.11',
                'ujson>=1.34',
                'spacy>=0.100,<0.101',
                'preshed>=0.46,<0.47',
                'murmurhash>=0.26,<0.27',
                'cymem>=1.30,<1.32',
                'sputnik>=0.9.0,<0.10.0'],
            classifiers=[
                'Development Status :: 4 - Beta',
                'Environment :: Console',
                'Intended Audience :: Developers',
                'Intended Audience :: Science/Research',
                'License :: OSI Approved :: MIT License',
                'Operating System :: POSIX :: Linux',
                'Operating System :: MacOS :: MacOS X',
                'Operating System :: Microsoft :: Windows',
                'Programming Language :: Cython',
                'Programming Language :: Python :: 2.6',
                'Programming Language :: Python :: 2.7',
                'Programming Language :: Python :: 3.3',
                'Programming Language :: Python :: 3.4',
                'Programming Language :: Python :: 3.5',
                'Topic :: Scientific/Engineering'],
            cmdclass = {
                'build_ext': build_ext_subclass},
        )


if __name__ == '__main__':
    setup_package()

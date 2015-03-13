gulp = require 'gulp'
coffee = require 'gulp-coffee'
mocha = require 'gulp-mocha'
rename = require 'gulp-rename'
del = require 'del'
chmod = require 'gulp-chmod'
{exec} = require('child_process')

gulp.task 'build', ->
    gulp.src('./src/*.coffee')
        .pipe(coffee())
        .pipe(gulp.dest './lib/')

gulp.task 'play', ->
    exec 'node_modules/coffee-script/bin/coffee src/bin.coffee'

gulp.task 'clean', ->
    del ['bin', 'lib']

gulp.task 'test', ->
    console.log 'someday there will be tests!'

gulp.task 'default', ->
    gulp.start('build')

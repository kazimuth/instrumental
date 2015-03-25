gulp = require 'gulp'
coffee = require 'gulp-coffee'
mocha = require 'gulp-mocha'
rename = require 'gulp-rename'
del = require 'del'
chmod = require 'gulp-chmod'
{exec} = require 'child_process'

gulp.task 'build', ->
    gulp.src('./src/*.coffee')
        .pipe(coffee())
        .pipe(gulp.dest './lib/')

gulp.task 'clean', ->
    del ['lib']

gulp.task 'test', ->
    console.log 'Someday there will be tests!'

gulp.task 'default', ->
    gulp.start 'build'

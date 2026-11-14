# Start here

**Level:** everyone · **Time:** 10 minutes · **You need:** a computer with Nim 2.0 or newer and a C compiler

By the end you have Retro Nim UI installed, a first app of your own running, and the tools you will use in every lesson: `retrokit` to make and run apps, `--live` to see each save at once, and Retro Designer to draw a window with the mouse.

## 1. Install

```sh
nimble install retroui
retrokit doctor                 # what your machine has, and how to fix what it lacks
```

`retrokit doctor` checks Nim, the C compiler, the screen libraries and, for phones, the Android tools. Each line it prints says what to do if something is missing. Nothing else is installed: the kit brings its own fonts, icons, PDF writer and picture decoders.

## 2. Make an app

```sh
retrokit new hello              # a folder hello/ with hello.nim, hello.nimble and an icon
cd hello
nimble run
```

`--kind:form`, `business`, `files` or `charts` start from a bigger app. Open `hello.nim`: the whole app is a dozen lines, and Lesson 1 explains each.

## 3. See each save at once

```sh
retrokit run hello.nim --watch
```

Change a label, save, and the window is built again where it was. Keep it open beside your editor through the lessons. `--size:360x640` shows the app at a phone's size, `--theme:Dark` in another color scheme, `--touch` with finger-sized controls.

## 4. Draw a window with the mouse

```sh
retrokit designer hello.nim
```

Retro Designer draws your file's windows with the real controls. Drop controls from the Widget Box, drag them where they go, set their properties; every change is written into the same `.nim` file, which you keep editing in your own editor.

## Where to go next

| Level | Lessons |
|---|---|
| Easy | [1 Hello](../01-hello/) · [2 A to-do list](../02-todo/) · [3 A tip calculator](../03-tip-calculator/) · [4 Notepad](../04-notepad/) |
| Intermediate | [5 Contacts](../05-contacts/) · [6 A news reader](../06-news-reader/) · [7 A dashboard](../07-dashboard/) · [8 Other languages](../08-translate/) |
| Mobile | [9 Phone layouts](../09-phone-layouts/) · [10 Android and iOS](../10-android-ios/) |
| Web | [11 The app as a web page](../11-web/) |
| Advanced | [12 Your own control](../12-own-control/) · [13 Your own loop, and threads](../13-own-loop-threads/) · [14 The system's own APIs](../14-system-apis/) · [15 Testing](../15-testing/) · [16 Shipping](../16-shipping/) |

## Arabic for Retro Files: the words of its menus, tool bar, dialogs and
## messages (the toolkit's own -- OK, Cancel, the file lists' -- are in
## retroui/lang_ar). Keys are the labels as the code has them, "&" taken out,
## as retroui/lang_ar's header says -- except the few texts the app looks up
## itself with `tr(...)`: their key is the literal exactly as written, an
## "&" included ("Rena&me ").
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

const filesArabic* = [
  # the views (View menu, the tool bar's Views)
  ("Details", "تفاصيل"),
  ("Tiles", "تجانب"),
  ("Medium icons", "أيقونات متوسطة"),
  ("Large icons", "أيقونات كبيرة"),
  ("Extra large icons", "أيقونات كبيرة جدًا"),
  ("Huge icons", "أيقونات ضخمة"),
  ("Small icons", "أيقونات صغيرة"),
  ("Columns", "أعمدة"),
  # tabs, places, the address bar
  ("This device", "هذا الجهاز"),
  ("Address", "العنوان"),
  ("Search ", "بحث في "),
  ("Search in all subfolders", "البحث في كل المجلدات الفرعية"),
  ("Go to", "الانتقال إلى"),
  # messages
  ("The folder ", "المجلد "),
  (" does not exist.", " غير موجود."),
  ("Waiting: ", "في الانتظار: "),
  (" starts when the job running ends", " تبدأ عندما تنتهي المهمة الجارية"),
  ("({n} more waiting)", "({n} أخرى في الانتظار)"),
  ("Duplicating", "جارٍ التكرار"),
  (" -- done.", " -- تم."),
  ("Cut ", "تم قص "),
  ("Copied ", "تم نسخ "),
  (". Paste them in another folder.", ". الصقها في مجلد آخر."),
  ("Clipboard", "الحافظة"),
  ("Cannot read ", "تعذرت قراءة "),
  (" (it may be too big to show here).", " (قد يكون أكبر من أن يُعرض هنا)."),
  ("Saved ", "تم حفظ "),
  ("Cannot save:\n", "تعذر الحفظ:\n"),
  ("This file is too big to edit here (more than 1 MB).", "هذا الملف أكبر من أن يُحرَّر هنا (أكثر من 1 MB)."),
  ("No app to open ", "لا يوجد تطبيق لفتح "),
  ("No app to share ", "لا يوجد تطبيق لمشاركة "),
  (" with.", "."),
  ("No terminal program was found.", "لم يُعثر على برنامج طرفية."),
  ("Nothing matches ", "لا شيء يطابق "),
  ("Something went wrong -- kept in the fault log: Help > Report a Problem", "حدث خطأ ما -- حُفظ في سجل الأعطال: تعليمات > الإبلاغ عن مشكلة"),
  ("Memory freed", "تم تحرير الذاكرة"),
  # new folder, new file, rename, zip (and what Undo calls them)
  ("New Folder", "مجلد جديد"),
  ("Name of the new folder:", "اسم المجلد الجديد:"),
  ("New File", "ملف جديد"),
  ("Name of the new file:", "اسم الملف الجديد:"),
  ("Rename", "إعادة تسمية"),
  ("New name:", "الاسم الجديد:"),
  ("Compress", "ضغط"),
  ("Name of the zip file:", "اسم ملف ZIP:"),
  ("New folder", "مجلد جديد"),
  ("New Text Document.txt", "مستند نصي جديد.txt"),
  ("New Document.md", "مستند جديد.md"),
  ("New folder ", "مجلد جديد "),
  ("New file ", "ملف جديد "),
  ("Rename ", "إعادة تسمية "),
  # the viewer
  ("Back (Esc)", "رجوع (Esc)"),
  ("Save (Ctrl+S)", "حفظ (Ctrl+S)"),
  ("Stop editing", "إيقاف التحرير"),
  ("Edit", "تحرير"),
  ("Preview", "معاينة"),
  ("Show the source", "إظهار المصدر"),
  ("Previous picture", "الصورة السابقة"),
  ("Next picture", "الصورة التالية"),
  ("Slide show (a picture every 3 seconds)", "عرض الشرائح (صورة كل 3 ثوانٍ)"),
  ("Fit to the window", "ملاءمة للنافذة"),
  ("Actual size", "الحجم الفعلي"),
  ("Extract all here", "استخراج الكل هنا"),
  ("Previous page (Left)", "الصفحة السابقة (Left)"),
  ("Next page (Right)", "الصفحة التالية (Right)"),
  ("Smaller (Ctrl+wheel, -)", "أصغر (Ctrl+عجلة الفأرة، -)"),
  ("Larger (Ctrl+wheel, +)", "أكبر (Ctrl+عجلة الفأرة، +)"),
  ("As wide as the window (0)", "بعرض النافذة (0)"),
  ("Open with another app", "فتح بتطبيق آخر"),
  ("Page", "صفحة"),
  ("This picture cannot be shown here.", "لا يمكن عرض هذه الصورة هنا."),
  ("Loading the picture...", "جارٍ تحميل الصورة..."),
  ("Packed", "الحجم المضغوط"),
  ("Title", "العنوان"),
  ("Title Case", "أول كل كلمة كبير"),
  ("Save changes?", "حفظ التغييرات؟"),
  ("Save the changes to ", "حفظ التغييرات في "),
  ("?", "؟"),
  ("Don't save", "عدم الحفظ"),
  # Copy To / Move To, Folder Sizes
  ("Move To Folder", "نقل إلى مجلد"),
  ("Copy To Folder", "نسخ إلى مجلد"),
  ("Folder Sizes", "أحجام المجلدات"),
  ("Measuring...", "جارٍ القياس..."),
  (" in all", " إجمالًا"),
  ("(the files here)", "(الملفات هنا)"),
  ("Double-click a folder to open it.", "انقر نقرًا مزدوجًا فوق مجلد لفتحه."),
  # the menu of the files
  ("Open in new tab", "فتح في علامة تبويب جديدة"),
  ("Open in the other pane", "فتح في الجزء الآخر"),
  ("Open with app...", "فتح باستخدام تطبيق..."),
  ("View as text", "عرض كنص"),
  ("View as hex", "عرض كست عشري"),
  ("Share...", "مشاركة..."),
  ("Copy to the other pane", "نسخ إلى الجزء الآخر"),
  ("Move to the other pane", "نقل إلى الجزء الآخر"),
  ("Copy To Folder...", "نسخ إلى مجلد..."),
  ("Move To Folder...", "نقل إلى مجلد..."),
  ("Compress to ZIP...", "ضغط إلى ZIP..."),
  ("Extract here", "استخراج هنا"),
  ("Copy as path", "نسخ كمسار"),
  ("Pin to favorites", "تثبيت في المفضلة"),
  ("New folder...", "مجلد جديد..."),
  # the menu of a tab
  ("Duplicate tab", "تكرار علامة التبويب"),
  ("Close tab", "إغلاق علامة التبويب"),
  ("Close other tabs", "إغلاق علامات التبويب الأخرى"),
  # View > as Web Page, the preview
  ("Select an item to view its description.", "حدد عنصرًا لعرض وصفه."),
  ("Size: ", "الحجم: "),
  ("Modified: ", "تاريخ التعديل: "),
  ("Attributes: Read-only", "السمات: للقراءة فقط"),
  (" selected.", " محدد."),
  ("Total file size: ", "الحجم الكلي للملفات: "),
  ("Restore items, or empty the trash.", "استعد العناصر، أو أفرغ سلة المحذوفات."),
  ("Pick a place to open it.", "اختر مكانًا لفتحه."),
  # Rename with several selected, Select Matching
  ("Rena&me ", "إعادة تسمية "),
  (" Items...", " عناصر..."),
  (" Items", " عناصر"),
  ("Name pattern:", "نمط الاسم:"),
  ("* the name as it is, ### a number (as many digits as #s); the extension stays.", "* الاسم كما هو، ### رقم (بعدد علامات #)؛ ويبقى الامتداد كما هو."),
  ("Number from", "الترقيم من"),
  ("Replace with:", "استبدال بـ:"),
  ("Letters", "الأحرف"),
  ("As they are", "كما هي"),
  ("lower", "أحرف صغيرة"),
  ("UPPER", "أحرف كبيرة"),
  ("Name now", "الاسم الحالي"),
  ("New name", "الاسم الجديد"),
  ("Select Matching", "تحديد المطابق"),
  ("Select the items named like (* any letters, ? one; several: *.jpg *.png):", "تحديد العناصر التي تشبه أسماؤها (* أي أحرف، ? حرف واحد؛ عدة أنماط: *.jpg *.png):"),
  # delete
  (" to the trash?", " إلى سلة المحذوفات؟"),
  ("Delete for good", "حذف نهائي"),
  (" for good?\nThis cannot be undone.", " نهائيًا؟\nلا يمكن التراجع عن ذلك."),
  # Folder Options
  ("Folder Options", "خيارات المجلد"),
  ("Look", "المظهر"),
  ("Work", "العمل"),
  ("Language", "اللغة"),
  ("Hidden files", "الملفات المخفية"),
  ("Names that start with a dot", "الأسماء التي تبدأ بنقطة"),
  ("File name extensions", "امتدادات أسماء الملفات"),
  ("\"notes.txt\" or \"notes\"", "\"notes.txt\" أو \"notes\""),
  ("Folder tree", "شجرة المجلدات"),
  ("Drive bar", "شريط محركات الأقراص"),
  ("The places as buttons under the tool bar", "الأماكن كأزرار أسفل شريط الأدوات"),
  ("Two panes", "جزءان"),
  ("Two folders side by side (F9)", "مجلدان جنبًا إلى جنب (F9)"),
  ("Preview pane", "جزء المعاينة"),
  ("Beside the list, or under it on a phone (F3)", "بجانب القائمة، أو أسفلها على الهاتف (F3)"),
  ("Preview follows the mouse", "المعاينة تتبع الفأرة"),
  ("Shows the item the mouse rests on", "تعرض العنصر الذي يستقر عليه مؤشر الفأرة"),
  ("Picture thumbnails", "الصور المصغرة"),
  ("Start in", "البدء في"),
  ("Last", "آخر مجلد"),
  ("Storage", "وحدة التخزين"),
  ("Its home folder, here too", "مجلده الرئيسي، هنا أيضًا"),
  ("Delete to the trash", "الحذف إلى سلة المحذوفات"),
  ("Deleted items can be restored (Shift+Del: for good)", "يمكن استعادة العناصر المحذوفة (Shift+Del: حذف نهائي)"),
  ("Ask before deleting", "السؤال قبل الحذف"),
  ("Open with one tap", "الفتح بنقرة واحدة"),
  ("On touch screens; a long press selects", "على شاشات اللمس؛ والضغط المطوّل يحدد"),
  ("Keep thumbnails on disk", "الاحتفاظ بالصور المصغرة على القرص"),
  ("Folders of photos, videos and documents open at once the second time", "تُفتح مجلدات الصور ومقاطع الفيديو والمستندات فورًا في المرة الثانية"),
  ("At most", "بحد أقصى"),
  ("Thumbnails", "الصور المصغرة"),
  ("Clear", "مسح"),
  (" kept on disk", " محفوظة على القرص"),
  ("Decoded again when they are shown", "يُعاد فك ترميزها عند عرضها"),
  ("Free now", "تحرير الآن"),
  # Help > Keyboard (the whole page is one text)
  ("Keyboard", "لوحة المفاتيح"),
  ("""
# Keyboard

| Keys | What they do |
|---|---|
| Enter | Open the folder or file |
| Backspace, Alt+Up | Up one folder |
| Alt+Left / Alt+Right | Back / Forward |
| Ctrl+T / Ctrl+W | New tab / close the tab |
| Ctrl+Tab | The next tab |
| F4, Alt+D, Ctrl+L | Type a path |
| Ctrl+F | Search |
| F9 / F6 | Two panes / the other pane |
| Shift+F5 / Shift+F4 | Cascade / tile the folders' windows (View > Folders in Windows) |
| Ctrl+F6 / Ctrl+F4 | The next window / close it |
| Ctrl+C, Ctrl+X, Ctrl+V | Copy, cut, paste |
| Ctrl+Z | Undo |
| Del / Shift+Del | To the trash / delete for good |
| F2 | Rename (several selected: by a pattern, "Holiday ###") |
| Ctrl+D | Duplicate |
| F3 | Search |
| Alt+P | Preview pane |
| F5 | Refresh |
| Ctrl+A / Ctrl+Shift+A | Select all / select matching (*.jpg) |
| Ctrl+Alt+T | Open a terminal here |
| Ctrl+Shift+N | New folder |
| Alt+Enter | Properties |
| Ctrl+wheel | Larger or smaller icons |
| Ctrl+Plus / Ctrl+Minus / Ctrl+0 | Larger, smaller, normal size |

In the columns view: Left and Right go up and into folders, Up and Down
along the column; type the first letters of a name to go to it.

Viewers: pictures (Left / Right, a slide show), PDF documents (Page Up /
Down, + / -, 0 as wide as the window), videos and sounds (Space plays and
pauses), text, Markdown, zip files.

With a mouse: drag files onto a folder, a tab, the path or the tree to
move them there (hold Ctrl to copy); drag on the empty part of a list to
select with a rectangle.

On a phone: tap opens, a long press shows the menu (keep the finger down
and move it to drag the file somewhere), **Select** in the tool bar puts
check boxes on the rows, and Back goes back a folder.
""", """
# لوحة المفاتيح

| المفاتيح | ما تفعله |
|---|---|
| Enter | فتح المجلد أو الملف |
| Backspace, Alt+Up | مستوى واحد لأعلى |
| Alt+Left / Alt+Right | رجوع / إلى الأمام |
| Ctrl+T / Ctrl+W | علامة تبويب جديدة / إغلاق علامة التبويب |
| Ctrl+Tab | علامة التبويب التالية |
| F4, Alt+D, Ctrl+L | كتابة مسار |
| Ctrl+F | بحث |
| F9 / F6 | جزءان / الجزء الآخر |
| Shift+F5 / Shift+F4 | ترتيب نوافذ المجلدات متتالية / متجانبة (عرض > المجلدات في نوافذ) |
| Ctrl+F6 / Ctrl+F4 | النافذة التالية / إغلاقها |
| Ctrl+C, Ctrl+X, Ctrl+V | نسخ، قص، لصق |
| Ctrl+Z | تراجع |
| Del / Shift+Del | إلى سلة المحذوفات / حذف نهائي |
| F2 | إعادة تسمية (عند تحديد عدة عناصر: بنمط، "Holiday ###") |
| Ctrl+D | تكرار |
| F3 | بحث |
| Alt+P | جزء المعاينة |
| F5 | تحديث |
| Ctrl+A / Ctrl+Shift+A | تحديد الكل / تحديد المطابق (*.jpg) |
| Ctrl+Alt+T | فتح طرفية هنا |
| Ctrl+Shift+N | مجلد جديد |
| Alt+Enter | خصائص |
| Ctrl+عجلة الفأرة | أيقونات أكبر أو أصغر |
| Ctrl+Plus / Ctrl+Minus / Ctrl+0 | أكبر، أصغر، الحجم العادي |

في عرض الأعمدة: ينتقل Left وRight إلى المجلد الأعلى وإلى داخل المجلدات، وUp وDown على طول العمود؛ واكتب الأحرف الأولى من اسم للانتقال إليه.

العارضات: الصور (Left / Right، وعرض الشرائح)، ومستندات PDF (Page Up / Down، و+ / -، و0 لملاءمة عرض النافذة)، ومقاطع الفيديو والأصوات (Space للتشغيل والإيقاف المؤقت)، والنصوص، وMarkdown، وملفات ZIP.

بالفأرة: اسحب الملفات إلى مجلد أو علامة تبويب أو المسار أو الشجرة لنقلها إليه (اضغط Ctrl للنسخ)؛ واسحب في الجزء الفارغ من القائمة للتحديد بمستطيل.

على الهاتف: النقر يفتح، والضغط المطوّل يُظهر القائمة (أبقِ إصبعك على الشاشة وحرّكه لسحب الملف إلى مكان ما)، و**تحديد** في شريط الأدوات يضع خانات اختيار على الصفوف، وزر الرجوع يعود مجلدًا واحدًا.
"""),
  # Help > About, Report a Problem
  ("About Retro Files", "حول Retro Files"),
  ("New in Retro Files 3.3:", "الجديد في Retro Files 3.3:"),
  ("View > Folders in Windows: each folder in a window of its own, as the 3.1 File " &
   "Manager had them (Window > Cascade, Tile) -- or in tabs, as before",
   "عرض > المجلدات في نوافذ: كل مجلد في نافذة خاصة به كما في مدير الملفات 3.1 " &
   "(نافذة > تتالٍ، تجانب) -- أو في علامات تبويب كما كان"),
  ("Always on Top: a folder's window kept over the others (the pin in its title bar, or the Window menu)",
   "دائماً في المقدمة: نافذة مجلد تبقى فوق غيرها (الدبوس في شريط عنوانها، أو قائمة نافذة)"),
  ("The About box's pages scroll inside their tab; on Windows a tooltip is no longer under the mouse pointer",
   "صفحات نافذة حول تتمرر داخل علامة تبويبها؛ وفي ويندوز لم يعد التلميح تحت مؤشر الفأرة"),
  ("Very big pictures (gigapixel scans, huge maps) shown and thumbnailed a band at a time: a few MB instead of their whole size",
   "الصور الكبيرة جدًا (المسح بمليارات النقاط، الخرائط الضخمة) تُعرض وتُصغَّر شريطًا بعد شريط: بضعة ميغابايتات بدل حجمها كله"),
  ("The memory no longer grows the longer it is used: what is let go of goes back to the system, the pictures kept follow the device's memory",
   "لم تعد الذاكرة تزداد مع طول الاستخدام: ما يُترك يعود إلى النظام، والصور المحفوظة تتبع ذاكرة الجهاز"),
  ("Arabic: lines that mix Arabic with numbers read right to left, in their order",
   "العربية: الأسطر التي تمزج العربية بالأرقام تُقرأ من اليمين إلى اليسار بترتيبها"),
  ("Your files, as in 1994", "ملفاتك، كما في 1994"),
  ("A file manager made with Retro Nim UI: tabs, two panes, a tree, columns, " &
   "thumbnails of almost every picture, previews, viewers, zip archives and PDFs.",
   "مدير ملفات مبني بـ Retro Nim UI: علامات تبويب، وجزءان، وشجرة، وأعمدة، وصور مصغرة " &
   "لكل الصور تقريبًا، ومعاينات، وعارضات، وأرشيفات ZIP وملفات PDF."),
  ("Copyright (c) 2026 Sultan Al Isaiee. MIT licence.", "حقوق النشر (c) 2026 Sultan Al Isaiee. ترخيص MIT."),
  ("Thumbnails of camera raw photos (CR3, NEF, ARW, DNG...), Photoshop and " &
   "Retro Photo documents, SVG, JPEG XL, WebP, TIFF, EXR, HEIC and AVIF",
   "صور مصغرة لصور الكاميرا الخام (CR3 وNEF وARW وDNG...) ومستندات Photoshop وRetro Photo " &
   "وSVG وJPEG XL وWebP وTIFF وEXR وHEIC وAVIF"),
  ("Thumbnails kept on disk: a folder opens at once the second time (Folder Options > Work)",
   "صور مصغرة محفوظة على القرص: يُفتح المجلد فورًا في المرة الثانية (خيارات المجلد > العمل)"),
  ("Smart memory: the caches follow the device's memory and let go when it " &
   "runs short or the app goes to the background",
   "ذاكرة ذكية: تتبع ذاكرات التخزين المؤقت ذاكرةَ الجهاز وتُحرَّر عندما تقل " &
   "أو ينتقل التطبيق إلى الخلفية"),
  ("Arabic interface, mirrored right to left (Folder Options > Look)",
   "واجهة عربية معكوسة من اليمين إلى اليسار (خيارات المجلد > المظهر)"),
  ("Tools > Folder Sizes: what takes the room", "أدوات > أحجام المجلدات: ما الذي يشغل المساحة"),
  ("Copy To Folder, Move To Folder, Send To, Share, New Markdown Document",
   "نسخ إلى مجلد، ونقل إلى مجلد، وإرسال إلى، ومشاركة، ومستند Markdown جديد"),
  ("Help > Report a Problem: a fault no longer closes the app",
   "تعليمات > الإبلاغ عن مشكلة: لم يعد العطل يُغلق التطبيق"),
  ("Faster with very large folders", "أسرع مع المجلدات الكبيرة جدًا"),
  ("Icons: Nerd Fonts symbols (MIT / OFL) and Retro's pixel icons.",
   "الأيقونات: رموز Nerd Fonts (MIT / OFL) وأيقونات Retro البكسلية."),
  ("Something went wrong in Retro Files (the last time it ran, or now) -- it went on, " &
   "your work is kept. What it said is below: add what you were doing, then send it, " &
   "so it can be put right.",
   "حدث خطأ ما في Retro Files (في آخر تشغيل له، أو الآن) -- واصل عمله، وعملك محفوظ. " &
   "ما ذكره موجود أدناه: أضف ما كنت تفعله، ثم أرسله، كي يمكن إصلاحه."),
  # the menu bar: File
  ("Send To", "إرسال إلى"),
  ("Compressed (zipped) folder", "مجلد مضغوط (ZIP)"),
  ("Folder...", "مجلد..."),
  ("The other pane", "الجزء الآخر"),
  ("New tab", "علامة تبويب جديدة"),
  ("Close the tab", "إغلاق علامة التبويب"),
  ("Duplicate", "تكرار"),
  ("Delete for good...", "حذف نهائي..."),
  ("Settings...", "الإعدادات..."),
  ("Exit", "إنهاء"),
  # Edit (its title: the viewer's "Edit" above)
  ("Select none", "إلغاء التحديد"),
  ("Invert selection", "عكس التحديد"),
  ("Select Matching...", "تحديد المطابق..."),
  ("Select with check boxes", "التحديد بخانات الاختيار"),
  # View
  ("View", "عرض"),
  ("Toolbars", "أشرطة الأدوات"),
  ("Standard Buttons", "الأزرار القياسية"),
  ("Drive Bar", "شريط محركات الأقراص"),
  ("Text Labels (under the icons)", "تسميات نصية (أسفل الأيقونات)"),
  ("Text Beside the Icons", "النص بجانب الأيقونات"),
  ("No Text Labels", "بدون تسميات نصية"),
  ("Text Only", "نص فقط"),
  ("Status Bar", "شريط الحالة"),
  ("Explorer Bar", "شريط المستكشف"),
  ("Preview Follows the Mouse", "المعاينة تتبع الفأرة"),
  ("As Web Page", "كصفحة ويب"),
  ("Arrange Icons", "ترتيب الأيقونات"),
  ("by Name", "حسب الاسم"),
  ("by Type", "حسب النوع"),
  ("by Size", "حسب الحجم"),
  ("by Date", "حسب التاريخ"),
  ("Two Panes", "جزءان"),
  ("File Name Extensions", "امتدادات أسماء الملفات"),
  ("Hidden Files", "الملفات المخفية"),
  ("Colors", "الألوان"),
  ("Normal Size", "الحجم العادي"),
  ("Refresh", "تحديث"),
  ("Folder Options...", "خيارات المجلد..."),
  # Go
  ("Go", "انتقال"),
  ("Back", "رجوع"),
  ("Forward", "إلى الأمام"),
  ("Up", "أعلى"),
  ("Go to folder...", "الانتقال إلى مجلد..."),
  # Favorites
  ("Add this folder", "إضافة هذا المجلد"),
  ("Remove this folder", "إزالة هذا المجلد"),
  # Tools
  ("Tools", "أدوات"),
  ("Find", "بحث"),
  ("Files or Folders...", "ملفات أو مجلدات..."),
  ("In All Subfolders...", "في كل المجلدات الفرعية..."),
  ("Go to Folder...", "الانتقال إلى مجلد..."),
  ("Open Terminal Here", "فتح الطرفية هنا"),
  ("Copy as Path", "نسخ كمسار"),
  ("Folder Sizes...", "أحجام المجلدات..."),
  ("Clear Thumbnail Cache", "مسح ذاكرة الصور المصغرة المؤقتة"),
  ("Free Memory", "تحرير الذاكرة"),
  # Help
  ("Report a Problem...", "الإبلاغ عن مشكلة..."),
  ("Retro Files on the Web", "Retro Files على الويب"),
  # the tool bar (labels and tool tips)
  ("Done (select none)", "تم (إلغاء التحديد)"),
  (" selected: select all", " محدد: تحديد الكل"),
  ("Delete (to the trash)", "حذف (إلى سلة المحذوفات)"),
  ("Select", "تحديد"),
  ("Settings", "الإعدادات"),
  ("Back (Alt+Left)", "رجوع (Alt+Left)"),
  ("Forward (Alt+Right)", "إلى الأمام (Alt+Right)"),
  ("Up one folder (Backspace)", "مستوى واحد لأعلى (Backspace)"),
  ("Cut (Ctrl+X)", "قص (Ctrl+X)"),
  ("Copy (Ctrl+C)", "نسخ (Ctrl+C)"),
  ("Paste (Ctrl+V)", "لصق (Ctrl+V)"),
  ("Undo (Ctrl+Z)", "تراجع (Ctrl+Z)"),
  ("Rename (F2; several: by a pattern)", "إعادة تسمية (F2؛ عدة عناصر: بنمط)"),
  ("Delete: to the trash (Del)", "حذف: إلى سلة المحذوفات (Del)"),
  ("Properties (Alt+Enter)", "خصائص (Alt+Enter)"),
  ("Refresh (F5)", "تحديث (F5)"),
  ("Views", "طرق العرض"),
  ("Views: how the files are shown", "طرق العرض: كيف تظهر الملفات"),
  ("New folder (Ctrl+Shift+N)", "مجلد جديد (Ctrl+Shift+N)"),
  ("The folder tree", "شجرة المجلدات"),
  ("Two panes (F9)", "جزءان (F9)"),
  ("Preview pane (Alt+P)", "جزء المعاينة (Alt+P)"),
  ("Find files or folders (F3)", "البحث عن ملفات أو مجلدات (F3)"),
  ("Options", "خيارات"),
  ("Folder options", "خيارات المجلد"),
  # Android: the permission
  (" needs permission to show and manage the files on this " &
   "device. Android asks once; you can change it later in the settings.",
   " يحتاج إلى إذن لعرض الملفات وإدارتها على هذا الجهاز. يطلب Android ذلك " &
   "مرة واحدة، ويمكنك تغييره لاحقًا من الإعدادات."),
  ("Use the app's folder", "استخدام مجلد التطبيق"),
  ("No access to the files yet.", "لا يوجد وصول إلى الملفات بعد."),
  # the status bar
  (" in the trash", " في سلة المحذوفات"),
  (" selected (", " محدد ("),
  ("Reading the folder...", "جارٍ قراءة المجلد..."),
  ("Cut: ", "قص: "),
  ("Copied: ", "منسوخ: "),
  # (the nouns Retro Files counts with `countText`: see retroui/lang_ar's " item")
  (" entry", " إدخال"),
  (" entries", " إدخالات"),
  (" found", " نتيجة"),
  (" place", " مكان"),
  (" places", " أماكن"),
  # (View > Folders in Windows: the folders in windows of their own)
  ("New Window", "نافذة جديدة"),
  ("Close the Window", "إغلاق النافذة"),
  ("Folders in Windows", "المجلدات في نوافذ"),
  ("Folders in Tabs", "المجلدات في علامات تبويب"),
  ("Window", "نافذة"),
  ("Folders open in", "تفتح المجلدات في"),
  ("Tabs", "علامات تبويب"),
  ("Windows", "نوافذ"),
  # (Tabs or Windows; the windows' size grip)
  ("The folders in tabs, or in windows of their own", "المجلدات في علامات تبويب، أو في نوافذ مستقلة"),
  ("Folders In", "المجلدات في"),
  ("New Tab", "علامة تبويب جديدة"),
  ("Close the Tab", "إغلاق علامة التبويب"),
  ("Windows' size grip", "مقبض تغيير حجم النوافذ"),
  ("At the lower right corner of each folder's window", "في الزاوية السفلية اليمنى من نافذة كل مجلد"),
  ("Small", "صغير"),
  ("Medium", "متوسط"),
  ("Large", "كبير"),
  ("Tabs or Windows: from the tool bar, View > Folders In or the Window menu; each window with a size " &
   "grip (Folder Options: none, small, medium, large); in a narrow window the search is a button",
   "علامات تبويب أو نوافذ: من شريط الأدوات أو عرض > المجلدات في أو قائمة نافذة؛ ولكل نافذة مقبض لتغيير " &
   "الحجم (خيارات المجلد: بلا، صغير، متوسط، كبير)؛ وفي النافذة الضيقة يصبح البحث زراً"),
  ("Always on Top waits while a window is maximized; room inside the folder tree's frame",
   "دائماً في المقدمة يتوقف أثناء تكبير النافذة؛ ومساحة داخل إطار شجرة المجلدات"),
  # (the folder tree's menu)
  ("Open in New Window", "فتح في نافذة جديدة"),
  ("Open in New Tab", "فتح في علامة تبويب جديدة"),
  ("Open in the Other Pane", "فتح في الجزء الآخر"),
  ("New Folder...", "مجلد جديد..."),
  ("Paste Into It", "لصق فيه"),
  ("Remove from Favorites", "إزالة من المفضلة"),
  ("Add to Favorites", "إضافة إلى المفضلة"),
  ("Empty the Trash", "إفراغ سلة المحذوفات"),
  ("Delete everything in the trash for good?\nThis cannot be undone.",
   "حذف كل ما في سلة المحذوفات نهائياً؟\nلا يمكن التراجع عن ذلك."),
  ("Empty", "إفراغ"),
  ("The folder tree: a right click (a long press) on a folder: open it in a new tab or window, new folder, " &
   "paste into it, favorites, its path, terminal, sizes, properties; the pin (Always on Top) works again",
   "شجرة المجلدات: النقر بالزر الأيمن (أو الضغط المطوّل) على مجلد: فتحه في علامة تبويب أو نافذة جديدة، مجلد جديد، " &
   "لصق فيه، المفضلة، مساره، الطرفية، الأحجام، الخصائص؛ ودبوس (دائماً في المقدمة) يعمل مجدداً"),
  ("The menus by the keyboard: Alt (pressed and let go) or F10 opens them, the " &
   "arrows go along and through them; a menu taller than the screen in even columns, submenus moved up to fit",
   "القوائم بلوحة المفاتيح: Alt (ضغطة وإفلات) أو F10 يفتحها، والأسهم تتنقل بينها وداخلها؛ " &
   "والقائمة الأطول من الشاشة في أعمدة متساوية، والقوائم الفرعية ترتفع لتتسع"),
]

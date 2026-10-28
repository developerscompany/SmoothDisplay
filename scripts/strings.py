#!/usr/bin/env python3
"""Regenerates Resources/*.lproj/Localizable.strings. English text is the key; add a translation for
every key in each language table below, then run: python3 scripts/strings.py
It fails when a key used in Sources/ has no translation, so a release never ships half-translated menus."""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UK = {
    "SmoothDisplay is in the menu bar": "SmoothDisplay живе в рядку меню",
    "Click the display icon in the menu bar to switch your external monitor to a Retina (HiDPI) mode, adjust its brightness and pick a color profile.\n\nTo control the monitor with the brightness keys, allow SmoothDisplay in System Settings › Privacy & Security › Accessibility when macOS asks.":
        "Натисніть значок монітора в рядку меню, щоб увімкнути на зовнішньому моніторі режим Retina (HiDPI), змінити яскравість і вибрати колірний профіль.\n\nЩоб керувати монітором клавішами яскравості, дозвольте SmoothDisplay у «Системних параметрах» › «Приватність і безпека» › «Доступність», коли macOS попросить.",
    "OK": "OK",
    "Monitor backlight (DDC/CI)": "Підсвітка монітора (DDC/CI)",
    "Software dimming: the monitor does not accept brightness over DDC/CI": "Програмне затемнення: монітор не приймає яскравість по DDC/CI",
    "The monitor ignores brightness commands, so dimming is done in software.": "Монітор ігнорує команди яскравості, тому затемнення програмне.",
    "For backlight control, turn off brightness-locking modes in the monitor's menu": "Щоб керувати підсвіткою, вимкніть у меню монітора режими, що блокують яскравість",
    "(e.g. MPRT, dynamic contrast, Eco, HDR).": "(наприклад MPRT, динамічний контраст, Eco, HDR).",
    "Check Monitor Again": "Перевірити монітор знову",
    "Checking whether the monitor accepts brightness commands…": "Перевіряю, чи монітор приймає команди яскравості…",
    "The monitor now accepts brightness commands: the keys and the slider control its backlight.": "Монітор тепер приймає команди яскравості: клавіші й повзунок керують підсвіткою.",
    "The monitor still ignores brightness commands. In its menu, make sure modes such as MPRT, dynamic contrast, Eco and HDR are off and Brightness is not greyed out.":
        "Монітор досі ігнорує команди яскравості. Перевірте в його меню, що MPRT, динамічний контраст, Eco і HDR вимкнені, а пункт «Яскравість» не сірий.",
    "No external monitor found": "Зовнішній монітор не знайдено",
    "Retina, smoothed": "Retina, згладжено",
    "not HiDPI, text is not smoothed": "без HiDPI, текст не згладжується",
    "Now: %@ · %@ · %ld Hz": "Зараз: %@ · %@ · %ld Гц",
    "More Retina Sizes": "Інші Retina-розміри",
    "Standard Mode, No HiDPI  (%@)": "Звичайний режим без HiDPI  (%@)",
    "Retina unlocked — reconnect the monitor cable": "Retina розблоковано — перепідключіть кабель монітора",
    "Unlock Retina Modes…": "Розблокувати Retina-режими…",
    "White point (profile built from the panel's real primaries)": "Біла точка (профіль з реальних кольорів матриці)",
    "macOS Factory Profile (from monitor data)": "Заводський профіль macOS (з даних монітора)",
    "Turn off True Tone on the built-in display when comparing": "Для порівняння вимкніть True Tone на вбудованому екрані",
    "Colors: %@": "Кольори: %@",
    "unknown": "невідомо",
    "Brightness Keys Control the Monitor Under the Pointer": "Клавіші яскравості керують монітором під курсором",
    "Allow Brightness Keys…": "Дозволити клавіші яскравості…",
    "Keep Mode After Reconnect and Sleep": "Тримати режим після перепідключення і сну",
    "Launch at Login": "Запускати при вході в систему",
    "Thinner Text (applies after apps restart)": "Тонший шрифт (діє після перезапуску програм)",
    "Display Settings…": "Налаштування моніторів…",
    "Check for Updates…": "Перевірити оновлення…",
    "Check for Updates Automatically": "Перевіряти оновлення автоматично",
    "About SmoothDisplay": "Про SmoothDisplay",
    "Quit SmoothDisplay": "Вийти з SmoothDisplay",
    "Couldn't switch to %@.": "Не вдалося перемкнути на %@.",
    "macOS did not accept the color profile.": "macOS не прийняла колірний профіль.",
    "Couldn't change Launch at Login: %@": "Не вдалося змінити автозапуск: %@",
    "Smooth text on non-Retina monitors, brightness keys and color profiles for external displays.":
        "Гладкий текст на моніторах без Retina, клавіші яскравості й колірні профілі для зовнішніх дисплеїв.",
    "Done. Unplug and reconnect the monitor cable (or restart the Mac); Retina modes will then appear in the menu.":
        "Готово. Від'єднайте й знову під'єднайте кабель монітора (або перезавантажте Mac), після цього в меню з'являться Retina-режими.",
    "Brightness": "Яскравість",
    "Like a MacBook without True Tone (D65, 6500K)": "Як MacBook без True Tone (D65, 6500K)",
    "Warmer, closer to True Tone (6000K)": "Тепліше, ближче до True Tone (6000K)",
    "Even Warmer (5500K)": "Ще тепліше (5500K)",
    "Monitor's Native White, No Correction": "Рідний білий монітора, без корекції",
    "Couldn't read the monitor's factory color profile.": "Не вдалося прочитати заводський профіль монітора.",
    "Retina — native size": "Retina — звичайний розмір",
    "Retina — 15% larger": "Retina — усе на 15% більше",
    "Retina — 25% larger": "Retina — усе на 25% більше",
    "Retina — one third larger": "Retina — усе на третину більше",
    "Retina — 1.5× larger": "Retina — усе в 1,5 раза більше",
    "Monitor %u": "Монітор %u",
    "Couldn't determine the monitor's resolution.": "Не вдалося визначити роздільність монітора.",
    "SmoothDisplay wants to unlock Retina modes for your monitor.": "SmoothDisplay хоче розблокувати Retina-режими для вашого монітора.",
    "Cancelled.": "Скасовано.",
    "Couldn't write the override file: %@": "Не вдалося записати файл перевизначення: %@",
    "No releases published yet.": "Релізів ще немає.",
    "Couldn't check for updates": "Не вдалося перевірити оновлення",
    "SmoothDisplay %@ is available": "Доступна SmoothDisplay %@",
    "You have version %@. Download the new version from GitHub?": "У вас версія %@. Завантажити нову версію з GitHub?",
    "Download": "Завантажити",
    "Later": "Пізніше",
    "You're up to date": "У вас найновіша версія",
    "SmoothDisplay %@ is the latest version.": "SmoothDisplay %@ — найновіша версія.",
}

RU = {
    "SmoothDisplay is in the menu bar": "SmoothDisplay живёт в строке меню",
    "Click the display icon in the menu bar to switch your external monitor to a Retina (HiDPI) mode, adjust its brightness and pick a color profile.\n\nTo control the monitor with the brightness keys, allow SmoothDisplay in System Settings › Privacy & Security › Accessibility when macOS asks.":
        "Нажмите значок монитора в строке меню, чтобы включить на внешнем мониторе режим Retina (HiDPI), изменить яркость и выбрать цветовой профиль.\n\nЧтобы управлять монитором клавишами яркости, разрешите SmoothDisplay в «Системных настройках» › «Конфиденциальность и безопасность» › «Универсальный доступ», когда macOS попросит.",
    "OK": "OK",
    "Monitor backlight (DDC/CI)": "Подсветка монитора (DDC/CI)",
    "Software dimming: the monitor does not accept brightness over DDC/CI": "Программное затемнение: монитор не принимает яркость по DDC/CI",
    "The monitor ignores brightness commands, so dimming is done in software.": "Монитор игнорирует команды яркости, поэтому затемнение программное.",
    "For backlight control, turn off brightness-locking modes in the monitor's menu": "Чтобы управлять подсветкой, отключите в меню монитора режимы, блокирующие яркость",
    "(e.g. MPRT, dynamic contrast, Eco, HDR).": "(например MPRT, динамический контраст, Eco, HDR).",
    "Check Monitor Again": "Проверить монитор снова",
    "Checking whether the monitor accepts brightness commands…": "Проверяю, принимает ли монитор команды яркости…",
    "The monitor now accepts brightness commands: the keys and the slider control its backlight.": "Монитор теперь принимает команды яркости: клавиши и ползунок управляют подсветкой.",
    "The monitor still ignores brightness commands. In its menu, make sure modes such as MPRT, dynamic contrast, Eco and HDR are off and Brightness is not greyed out.":
        "Монитор всё ещё игнорирует команды яркости. Проверьте в его меню, что MPRT, динамический контраст, Eco и HDR выключены, а пункт «Яркость» не серый.",
    "No external monitor found": "Внешний монитор не найден",
    "Retina, smoothed": "Retina, сглажено",
    "not HiDPI, text is not smoothed": "без HiDPI, текст не сглаживается",
    "Now: %@ · %@ · %ld Hz": "Сейчас: %@ · %@ · %ld Гц",
    "More Retina Sizes": "Другие размеры Retina",
    "Standard Mode, No HiDPI  (%@)": "Обычный режим без HiDPI  (%@)",
    "Retina unlocked — reconnect the monitor cable": "Retina разблокирован — переподключите кабель монитора",
    "Unlock Retina Modes…": "Разблокировать режимы Retina…",
    "White point (profile built from the panel's real primaries)": "Белая точка (профиль из реальных цветов матрицы)",
    "macOS Factory Profile (from monitor data)": "Заводской профиль macOS (из данных монитора)",
    "Turn off True Tone on the built-in display when comparing": "Для сравнения выключите True Tone на встроенном экране",
    "Colors: %@": "Цвета: %@",
    "unknown": "неизвестно",
    "Brightness Keys Control the Monitor Under the Pointer": "Клавиши яркости управляют монитором под курсором",
    "Allow Brightness Keys…": "Разрешить клавиши яркости…",
    "Keep Mode After Reconnect and Sleep": "Сохранять режим после переподключения и сна",
    "Launch at Login": "Запускать при входе в систему",
    "Thinner Text (applies after apps restart)": "Более тонкий шрифт (после перезапуска программ)",
    "Display Settings…": "Настройки мониторов…",
    "Check for Updates…": "Проверить обновления…",
    "Check for Updates Automatically": "Проверять обновления автоматически",
    "About SmoothDisplay": "О программе SmoothDisplay",
    "Quit SmoothDisplay": "Завершить SmoothDisplay",
    "Couldn't switch to %@.": "Не удалось переключить на %@.",
    "macOS did not accept the color profile.": "macOS не приняла цветовой профиль.",
    "Couldn't change Launch at Login: %@": "Не удалось изменить автозапуск: %@",
    "Smooth text on non-Retina monitors, brightness keys and color profiles for external displays.":
        "Гладкий текст на мониторах без Retina, клавиши яркости и цветовые профили для внешних дисплеев.",
    "Done. Unplug and reconnect the monitor cable (or restart the Mac); Retina modes will then appear in the menu.":
        "Готово. Отключите и снова подключите кабель монитора (или перезагрузите Mac), после этого в меню появятся режимы Retina.",
    "Brightness": "Яркость",
    "Like a MacBook without True Tone (D65, 6500K)": "Как MacBook без True Tone (D65, 6500K)",
    "Warmer, closer to True Tone (6000K)": "Теплее, ближе к True Tone (6000K)",
    "Even Warmer (5500K)": "Ещё теплее (5500K)",
    "Monitor's Native White, No Correction": "Родной белый монитора, без коррекции",
    "Couldn't read the monitor's factory color profile.": "Не удалось прочитать заводской профиль монитора.",
    "Retina — native size": "Retina — обычный размер",
    "Retina — 15% larger": "Retina — всё на 15% крупнее",
    "Retina — 25% larger": "Retina — всё на 25% крупнее",
    "Retina — one third larger": "Retina — всё на треть крупнее",
    "Retina — 1.5× larger": "Retina — всё в 1,5 раза крупнее",
    "Monitor %u": "Монитор %u",
    "Couldn't determine the monitor's resolution.": "Не удалось определить разрешение монитора.",
    "SmoothDisplay wants to unlock Retina modes for your monitor.": "SmoothDisplay хочет разблокировать режимы Retina для вашего монитора.",
    "Cancelled.": "Отменено.",
    "Couldn't write the override file: %@": "Не удалось записать файл переопределения: %@",
    "No releases published yet.": "Релизов пока нет.",
    "Couldn't check for updates": "Не удалось проверить обновления",
    "SmoothDisplay %@ is available": "Доступна SmoothDisplay %@",
    "You have version %@. Download the new version from GitHub?": "У вас версия %@. Скачать новую версию с GitHub?",
    "Download": "Скачать",
    "Later": "Позже",
    "You're up to date": "У вас последняя версия",
    "SmoothDisplay %@ is the latest version.": "SmoothDisplay %@ — последняя версия.",
}

def source_keys():
    keys = []
    for path in sorted(glob.glob(os.path.join(ROOT, "Sources", "*.swift"))):
        for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', open(path, encoding="utf-8").read()):
            key = m.group(1).encode().decode("unicode_escape").encode("latin-1").decode("utf-8")
            if key not in keys:
                keys.append(key)
    return keys

def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

def write(lang, table, keys):
    path = os.path.join(ROOT, "Resources", f"{lang}.lproj", "Localizable.strings")
    lines = ["/* Generated by scripts/strings.py — edit the tables there. */", ""]
    lines += [f"{quote(k)} = {quote(table[k])};" for k in keys]
    open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")

keys = source_keys()
missing = [(lang, k) for lang, t in (("uk", UK), ("ru", RU)) for k in keys if k not in t]
if missing:
    for lang, k in missing:
        print(f"missing {lang}: {k!r}", file=sys.stderr)
    sys.exit(1)
write("en", {k: k for k in keys}, keys)
write("uk", UK, keys)
write("ru", RU, keys)
print(f"{len(keys)} keys written for en, uk, ru")

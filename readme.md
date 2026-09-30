# Compare-Hashtable

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-15%2F15%20PASS-brightgreen.svg)](#tests)

## [EN] English

Fast comparison of two hashtables in PowerShell with a precompiled C# engine. Returns an array
of differences: for each key - the key, a side marker (`<=` left-only, `!=` value mismatch,
`=>` right-only) and both values (`lvalue`, `rvalue`). Works on Windows PowerShell 5.1 and
PowerShell 7+ (including .NET 10). Orders of magnitude faster than a pure PowerShell
implementation on large tables.

### Usage

```powershell
. .\inc\Compare-Hashtable.ps1

Compare-Hashtable @{ a = 1; b = 2; c = 3 } @{ b = 2; c = 4; e = 5 }

# key lvalue rvalue side
# --- ------ ------ ----
# a         1      <=
# c   3      4     !=
# e         5      =>
```

Optional parameters: `PropertyName` - compare objects by this property (e.g. MD5 hash),
`outputValueName` - put this property into the output instead of whole objects.

Value equality (PowerShell-compatible): strings case-insensitively (ordinal); byte[] and
arrays element-wise; numeric types unified (`3 -eq 3.0`); mixed pairs like `1` and `"1"`
are different (no type coercion).

### How it works

The wrapper passes both tables to a static C# class `FastCompare.HashtableDiff` compiled once
per session via `Add-Type`. It makes a single pass over the left table, then a single pass over
the right one - no data loss, no duplicate keys. Property access uses PSObject members, then
cached compiled CLR getters, then the PowerShell adapter layer. The reference assembly set is
resolved automatically: default references on PS 7+, an explicit complete list on PS 5.1.

### Tests

All 15 scenarios PASS (PowerShell 7.6 / .NET 10). Synthetic tables contain strings, numbers
and byte[] values; expected diff counts are exact; timing via Stopwatch.

| Scenario | Keys (L/R) | Diffs | Result | Time |
|---|---:|---:|:---:|---:|
| Identical_100000 | 100000 / 100000 | 0 | PASS | 0.04 ms |
| FullyChanged_100000 | 100000 / 100000 | 100000 | PASS | 59.0 ms |
| Overlap_100000_10pct | 100000 / 100000 | 20000 | PASS | 42.9 ms |
| Stress_500000 | 500000 / 500000 | 500000 | PASS | 393.7 ms |

Benchmark (100k fully changed keys, 5 runs): avg ~64 ms. Scaling is close to linear.
Run tests: `pwsh -File .\test-Compare-Hashtable.ps1` (exit code 0/1, CI-friendly).

## [RU] Русский

Быстрое сравнение двух хэштаблиц в PowerShell на прекомпилированном C#-движке. Возвращает
массив отличий: для каждого ключа - ключ, маркер стороны (`<=` только слева, `!=` значения
различаются, `=>` только справа) и оба значения (`lvalue`, `rvalue`). Работает в Windows
PowerShell 5.1 и PowerShell 7+ (включая .NET 10). На больших таблицах - на порядки быстрее
чисто PowerShell-реализации.

### Использование

```powershell
. .\inc\Compare-Hashtable.ps1

Compare-Hashtable @{ a = 1; b = 2; c = 3 } @{ b = 2; c = 4; e = 5 }

# key lvalue rvalue side
# --- ------ ------ ----
# a         1      <=
# c   3      4     !=
# e         5      =>
```

Необязательные параметры: `PropertyName` - сравнивать объекты по указанному свойству
(например, MD5-хэшу), `outputValueName` - выводить в результат это свойство вместо целых
объектов.

Равенство значений (PowerShell-совместимое): строки без учёта регистра; byte[] и массивы -
поэлементно; числа разных типов унифицируются (`3 -eq 3.0`); смешанные пары вроде `1` и `"1"`
считаются разными (без неявной конвертации типов).

### Как это работает

Обёртка передаёт обе таблицы в статический C#-класс `FastCompare.HashtableDiff`, компилируемый
один раз за сессию через `Add-Type`. Выполняется один проход по левой таблице, затем один по
правой - без потери данных и дубликатов ключей. Доступ к свойствам: члены PSObject, затем
кэшированные скомпилированные CLR-геттеры, затем адаптерный слой PowerShell. Набор ссылок
сборок определяется автоматически: дефолтные ссылки на PS 7+, полный явный список на PS 5.1.

### Тесты

Все 15 сценариев PASS (PowerShell 7.6 / .NET 10). Синтетические таблицы содержат строки, числа
и byte[]; ожидаемые количества отличий вычисляются точно; замер времени через Stopwatch.

| Сценарий | Ключей (L/R) | Отличий | Результат | Время |
|---|---:|---:|:---:|---:|
| Identical_100000 | 100000 / 100000 | 0 | PASS | 0.04 мс |
| FullyChanged_100000 | 100000 / 100000 | 100000 | PASS | 59.0 мс |
| Overlap_100000_10pct | 100000 / 100000 | 20000 | PASS | 42.9 мс |
| Stress_500000 | 500000 / 500000 | 500000 | PASS | 393.7 мс |

Бенчмарк (100k полностью изменённых ключей, 5 запусков): в среднем ~64 мс. Масштабирование
близко к линейному. Запуск тестов: `pwsh -File .\test-Compare-Hashtable.ps1` (код выхода 0/1,
пригодно для CI).

## License / Лицензия

[MIT](LICENSE)


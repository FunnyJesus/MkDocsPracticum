# Git

Git — распределённая система контроля версий

`~HEAD` - указатель на текущую ветку или прямо на коммит

>commit 8d50bdc760d773c22113fc7d3e353ecf099c7e13 (HEAD -> main, origin/main, origin/HEAD)
>
>Author: Райн Гослинг <118374481+Driver@users.noreply.github.com>
>Date:   Sun May 10 14:31:19 2026 +0300
>
>    Initial commit

hash - уникальный код коммита. Для удобства можно использовать первые 7 символов хеша вместо всех 40.

> Команды Git — на странице [Git: команды с подробным описанием](git-commands.md).
> Мини-шпаргалка: [Git: шпаргалка топ-20 команд](git-cheatsheet.md).

## Обязательные атрибуты 

### Игнорирование файлов или каталогов 

* `.gitignore` - файл, в котором содержаться имена файлов или целых каталогов, которые будут игнорировать при сохранении изменений

!!! Пример содежимого
    ``` 
    .terraform // файл
    terraform.tfstate
    terraform.tfstate.backup
    /test // каталог
    ```

### Разрешение конфликтов

Кофликты появляются, когда сливают две ветки кода, но изменения в них противоречат друг другу. `Git` автоматически не решает конфдикты, поэтому их нужно решать самому 

#### Алгоритм 

Пример: в основной ветке main разработчик изменил логику расчёта итоговой цены в корзине интернет-магазина, заменив фиксированную скидку discount на новую функцию calculate_seasonal_discount(). Тем временем в ветке feature/free-shipping в той же строке добавили учёт бесплатной доставки вызовом apply_free_shipping().
Алгоритм разрешения:
1. Открыть конфликтный файл `cart.py`.
2. Найти маркеры `<<<<<<<, =======, >>>>>>>`.
```
    # ... previous code ...
<<<<<<< HEAD
    total = apply_discount(total, calculate_seasonal_discount())
=======
    total = apply_free_shipping(total)
>>>>>>> feature/free-shipping
    return total
```
3. Выбрать нужный вариант или написать новый.
4. Удалить маркеры конфликта.
```
    # ... previous code ...
    total = apply_discount(total, calculate_seasonal_discount())
    total = apply_free_shipping(total)
    return total
```
5. Сохранить файл. <br>
6. Выполнить `git add cart.py` и `git commit`.

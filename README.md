# Умный роутинг выплат

Механизм распределения выплатных операций между платёжными провайдерами:
фильтрация допустимых провайдеров, выбор лучшего по комбинации,
каскад при отказе и объяснимость каждого решения.

## Стек

Ruby 3.4, стандартная библиотека (`json`, `csv`, `yaml`). Внешних зависимостей нет 
решение запускается на голом Ruby. RSpec и RuboCop подключены ток для разработки



## Запуск

```
ruby bin/route  --queue data/operations_queue_test.json --out routing_decisions_test.json
ruby bin/report --decisions routing_decisions_test.json --out routing_report_test.json
ruby scripts/validate_10.rb out/routing_decisions_10.json
```

## Кто делал?? 

Хурматуллин Тимур, НИУ ВШЭ

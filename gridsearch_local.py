#!/usr/bin/env python

from sklearn.datasets import load_digits
from sklearn.svm import SVC
from sklearn.model_selection import GridSearchCV
from sklearn.model_selection import train_test_split as tts
from sklearn.metrics import classification_report
# from src import myfoo # An example included from `src`

param_space = {'C': [1e-4, 1, 1e4],
               'gamma': [1e-3, 1, 1e3],
               'class_weight': [None, 'balanced']}

model = SVC(kernel='rbf')

digits = load_digits()

X_train, X_test, y_train, y_test = tts(digits.data, digits.target,
                                       test_size=0.3)

print("Start searching")
search = GridSearchCV(model, param_space, cv=3)
search.fit(X_train, y_train)

print("Prepare report")
print(classification_report(
    y_true=y_test, y_pred=search.best_estimator_.predict(X_test))
)

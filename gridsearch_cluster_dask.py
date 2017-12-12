#!/usr/bin/env python

import sys
from sklearn.datasets import load_digits
from sklearn.svm import SVC
from sklearn.model_selection import train_test_split as tts
from sklearn.metrics import classification_report
from distributed import Client
from dask_searchcv import GridSearchCV
# from src import myfoo # An example included from `src`


def main(cluster_ip):
    param_space = {'C': [1e-4, 1, 1e4],
                   'gamma': [1e-3, 1, 1e3],
                   'class_weight': [None, 'balanced']}

    model = SVC(kernel='rbf')

    digits = load_digits()

    X_train, X_test, y_train, y_test = tts(digits.data, digits.target,
                                           test_size=0.3)

    cluster_ip = cluster_ip + ':' + '8786'
    print("Starting cluster at {}".format(cluster_ip))
    client = Client(cluster_ip)
    print(client)

    print("Start searching")
    search = GridSearchCV(model, param_space, cv=3)
    search.fit(X_train, y_train)

    print("Prepare report")
    print(classification_report(
        y_true=y_test, y_pred=search.best_estimator_.predict(X_test))
    )


if __name__ == '__main__':
    cluster_ip = sys.argv[1]
    main(cluster_ip)

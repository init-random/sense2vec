from __future__ import print_function
import sense2vec
import numpy as np
import timeit


def most_sim(model, words, num_most_sim):
    for w in words:
        freq, query_vector = model[w]
        # just compute; disregard output
        x = model.most_similar(query_vector, n=num_most_sim)


if __name__ == '__main__':

    model = sense2vec.load()

    n = [50, 100, 500, 1000]
    n_max = max(n)
    num_most_sim = 50
    arr = np.empty((n_max, ), dtype=np.dtype([('word', object), ('freq', np.int)]))

    for m in model:
        freq = m[1]
        if freq is None: continue
        argmin = arr['freq'].argmin()
        minval = arr['freq'][argmin]
        if freq > minval:
                arr[argmin] = m[:2]

    arr.sort(order='freq')
    arr = arr[::-1]

    for _n in n:
        start = timeit.default_timer()
        most_sim(model, arr["word"][:_n], num_most_sim)
        end = timeit.default_timer()
        delta = end - start
        print('Similarity timing for top %s model terms.' % (str(_n)))
        print('Finding top %s most similar terms for each model term.' % (str(num_most_sim)))
        print('%s similarity calculations.' % (str(_n * num_most_sim)))
        print('Completed in %s seconds.' % (str(delta)))
        print('----------------------------------------------------------\n')





"""
Lookup gene from a bed file with either
a cythonized dictionary or sqlite depending
on the size of the bedfile
Lookup method is transparent to the user
"""
import sys
import os
import sqlite3
from subprocess import check_output as sub
from collections import defaultdict

# Lets use C++ libraries to save memory
from libcpp.vector cimport vector
from libcpp.string cimport string

# Define max length to use dictionary
_max_len = 1000000  # 500,000 is a reasonable default


# C++ Structures to save memory
cdef struct StartEnd:
    long start, end
    string name

cdef class VecHolder:
   cdef public vector[StartEnd] wrapped_vector
   def __getitem__(self, key):
       return self.wrapped_vector[key]
   def push_back(self,obj):
     self.wrapped_vector.push_back(obj)

class BedFile():
    """ A Lookup Object """

    def lookup(self, chromosome, location):
        """ Lookup your gene. Returns the gene name """
        if self._type == 'sq':
            return self._lookup_sqlite(chromosome, str(location))
        elif self._type == 'dt':
            return self._lookup_dict(chromosome, location)

    # Private functions
    def _lookup_sqlite(self, chromosome, location):
        """ Simple sqlite query """
        expr = "SELECT name FROM '" + chromosome + "' INDEXED BY '" + \
               chromosome + "_start_end' " + "WHERE " + location + \
               " BETWEEN start AND end"
        try:
            self._c.execute(expr)
        except sqlite3.OperationalError as e:
            if str(e).startswith('no such table'):
                sys.stderr.write("\nWARNING --> Chromosome '" + chromosome +
                                 "' is not in the lookup table, lookup failed.\n")
                return ''
            else:
                raise(e)

        answer = self._c.fetchone()
        if answer:
            return answer[0]
        else:
            sys.stderr.write("\nWARNING --> Location '" + location +
                             "' on Chromosome '" + chromosome +
                             "' is not in the lookup table, lookup failed.\n")
            return ''

    def _lookup_dict(self, chromosome, location):
        """ Simple dictionary query with cython for math """
        answer = ''
        cdef long loc
        cdef string c_string
        loc = int(location)
        try:
            for i in range(len(self._dict[chromosome].wrapped_vector)):
                if self._dict[chromosome].wrapped_vector[i]['start'] \
                       < loc \
                       < self._dict[chromosome].wrapped_vector[i]['end']:
                    c_string = self._dict[chromosome].wrapped_vector[i]['name']
                    answer = c_string.decode()
                    break
        except KeyError:
            sys.stderr.write("\nWARNING --> Chromosome '" + chromosome +
                             "' is not in the lookup table, lookup failed.\n")
            return ''

        if answer:
            return answer
        else:
            sys.stderr.write("\nWARNING --> Location '" + location +
                             "' on Chromosome '" + chromosome +
                             "' is not in the lookup table, lookup failed.\n")
            return ''

    def _init_sqlite(self, bedfile):
        """ Initialize sqlite3 object """
        sys.stderr.write('INFO --> Bedfile is large, using sqlite\n')
        db_name = bedfile + '.db'
        if os.path.exists(db_name):
            sys.stderr.write('INFO --> Using existing db, if this is ' +
                             'not what you want, delete ' + db_name + '\n')
            self._conn = sqlite3.connect(db_name)
            self._c = self._conn.cursor()
            return

        # Create an sqlite database from bed file
        sys.stderr.write('INFO --> Creating sqlite database, this ' +
                         'may take a long time.\n')
        self._conn = sqlite3.connect(db_name)
        self._c = self._conn.cursor()

        with open(bedfile) as infile:
            for line in infile:
                f = line.rstrip().split('\t')
                if len(f) < 4:
                    continue
                # Check if db exists and create if it does
                self._c.execute("SELECT * FROM sqlite_master WHERE name ='" + f[0] + "' and type='table';")
                if not self._c.fetchall():
                    exp = "CREATE TABLE '" + f[0] + "' (name text, start int, end int);"
                    self._c.execute(exp)
                    self._conn.commit()
                self._c.execute("INSERT INTO '" + f[0] + "' VALUES ('" + f[3] + "','" + f[1] + "','" + f[2] + "')")
            self._conn.commit()
            # Create indicies
            self._c.execute('''SELECT name FROM sqlite_master WHERE type='table';''')
            for i in self._c.fetchall():
                exp = "CREATE INDEX '" + i[0] + "_start_end' ON '" + i[0] + "' (start, end) "
                self._c.execute(exp)
                self._conn.commit()

    def _init_dict(self, bedfile):
        self._dict = {}
        cdef vector[StartEnd] vect
        cdef StartEnd t
        with open(bedfile) as infile:
            for line in infile:
                f = line.rstrip().split('\t')
                if len(f) < 4:
                    continue
                chr   = f[0]
                start = int(f[1])
                end   = int(f[2])
                gene  = f[3].encode()
                t.start = start
                t.end = end
                t.name = gene
                if chr not in self._dict:
                    self._dict[chr] = VecHolder()
                self._dict[chr].push_back(t)

    def __init__(self, bedfile):
        if int(sub(['wc', '-l', bedfile]).decode().split(' ')[0]) > _max_len:
            # Use sqlite for files greater than max len
            self._type = 'sq'
            self._init_sqlite(bedfile)
        else:
            self._type = 'dt'
            self._init_dict(bedfile)

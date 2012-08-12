'''
Java wrapper
============

With this module, you can create Python class that reflect a Java class, and use
it directly in Python. For example, if you have a Java class named
Hardware.java, in org/test directory::

    public class Hardware {
        static int getDPI() {
            return metrics.densityDpi;
        }
    }

You can create this Python class to use it::

    class Hardware(JavaClass):
        __javaclass__ = 'org/test/Hardware'
        getDPI = JavaStaticMethod('()I')

And then, do::

    hardware = Hardware()
    hardware.getDPI()

Limitations
-----------

- Even if the method is static in Java, you need to instanciate the object in
  Python.
- Array currently not supported
'''

__all__ = ('JavaObject', 'JavaClass', 'JavaMethod', 'JavaStaticMethod')

include "jni.pxi"
from libc.stdlib cimport malloc, free


cdef tuple parse_definition(definition):
    args, ret = definition[1:].split(')')
    if args:
        args = args.split(';')
        if args[-1] == '':
            args.pop(-1)
    else:
        args = []
    return ret, args


class JavaException(Exception):
    '''Can be a real java exception, or just an exception from the wrapper.
    '''
    pass


cdef class JavaObject(object):
    '''Can contain any Java object. Used to store instance, or whatever.
    '''

    cdef jobject obj

    def __cinit__(self):
        self.obj = NULL


cdef class JavaClass(object):
    '''Main class to do introspection.
    '''

    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef jobject j_self

    def __cinit__(self, *args):
        self.j_env = NULL
        self.j_cls = NULL
        self.j_self = NULL

    def __init__(self, *args):
        super(JavaClass, self).__init__()
        self.resolve_class()
        self.resolve_methods()
        self.call_constructor(args)

    cdef void call_constructor(self, args):
        # the goal is to found the class constructor, and call it with the
        # correct arguments.
        cdef jvalue *j_args = NULL

        # get the constructor definition if exist
        definition = '()V'
        if hasattr(self, '__javaconstructor__'):
            definition = self.__javaconstructor__
        self.definition = definition
        d_ret, d_args = parse_definition(definition)
        if len(args) != len(d_args):
            raise JavaException('Invalid call, number of argument'
                    ' mismatch for constructor')

        try:
            # convert python arguments to java arguments
            if len(args):
                j_args = <jvalue *>malloc(sizeof(jvalue) * len(d_args))
                if j_args == NULL:
                    raise MemoryError('Unable to allocate memory for java args')
                self.populate_args(d_args, j_args, args)

            # get the java constructor
            cdef jmethodID constructor = self.j_env[0].GetMethodID(
                self.j_env, self.j_cls, '<init>', <char *><bytes>definition)
            if constructor == NULL:
                raise JavaException('Unable to found the constructor'
                        ' for {0}'.format(self.__javaclass__))

            # create the object
            self.j_self = self.j_env[0].NewObjectA(self.j_env, self.j_cls,
                    constructor, j_args)

        finally:
            if j_args != NULL:
                free(j_args)

    cdef void resolve_class(self):
        # search the Java class, and bind to our object
        if not hasattr(self, '__javaclass__'):
            raise JavaException('__javaclass__ definition missing')

        self.j_env = SDL_ANDROID_GetJNIEnv()
        if self.j_env == NULL:
            raise JavaException('Unable to get the Android JNI Environment')

        self.j_cls = self.j_env[0].FindClass(self.j_env,
                <char *><bytes>self.__javaclass__)
        if self.j_cls == NULL:
            raise JavaException('Unable to found the class'
                    ' {0}'.format(self.__javaclass__))

    cdef void resolve_methods(self):
        # search all the JavaMethod within our class, and resolve them
        cdef JavaMethod jm
        for name in dir(self.__class__):
            value = getattr(self.__class__, name)
            if not isinstance(value, JavaMethod):
                continue
            jm = value
            jm.resolve_method(self, name)

    cdef void populate_args(self, list definition_args, jvalue *j_args, args):
        # do the conversion from a Python object to Java from a Java definition
        cdef JavaObject j_object
        for index, argtype in enumerate(definition_args):
            py_arg = args[index]
            if argtype == 'Z':
                j_args[index].z = py_arg
            elif argtype == 'B':
                j_args[index].b = py_arg
            elif argtype == 'C':
                j_args[index].c = py_arg
            elif argtype == 'S':
                j_args[index].s = py_arg
            elif argtype == 'I':
                j_args[index].i = py_arg
            elif argtype == 'J':
                j_args[index].j = py_arg
            elif argtype == 'F':
                j_args[index].f = py_arg
            elif argtype == 'D':
                j_args[index].d = py_arg
            elif argtype[0] == 'L':
                if argtype == 'Ljava/lang/String':
                    if isinstance(py_arg, basestring):
                        j_args[index].l = self.j_env[0].NewStringUTF(
                                self.j_env, <char *><bytes>py_arg)
                    elif py_arg is None:
                        j_args[index].l = NULL
                    else:
                        raise JavaException('Not a correct type of string, '
                                'must be an instance of str or unicode')
                else:
                    if not isinstance(py_arg, JavaObject):
                        raise JavaException('JavaObject needed for argument '
                                '{0}'.format(index))
                    j_object = py_arg
                    j_args[index].l = j_object.obj
            elif argtype[0] == '[':
                raise NotImplemented('List arguments not accepted')


cdef class JavaMethod(object):
    '''Used to resolve a Java method, and do the call
    '''
    cdef jmethodID j_method
    cdef JavaClass jc
    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef jobject j_self
    cdef char *definition
    cdef object is_static
    cdef object definition_return
    cdef object definition_args

    def __cinit__(self, definition, **kwargs):
        self.j_method = NULL
        self.j_env = NULL
        self.j_cls = NULL

    def __init__(self, definition, **kwargs):
        super(JavaMethod, self).__init__()
        self.definition = <char *><bytes>definition
        self.definition_return, self.definition_args = parse_definition(definition)
        self.is_static = kwargs.get('static', False)

    cdef resolve_method(self, JavaClass jc, bytes name):
        # called by JavaClass when we want to resolve the method name
        self.jc = jc
        self.j_env = jc.j_env
        self.j_cls = jc.j_cls
        self.j_self = jc.j_self
        if self.is_static:
            self.j_method = self.j_env[0].GetStaticMethodID(
                    self.j_env, self.j_cls, <char *>name, self.definition)
        else:
            self.j_method = self.j_env[0].GetMethodID(
                    self.j_env, self.j_cls, <char *>name, self.definition)
        assert(self.j_method != NULL)

    def __call__(self, *args):
        # argument array to pass to the method
        cdef jvalue *j_args = NULL
        cdef list d_args = self.definition_args
        if len(args) != len(d_args):
            raise JavaException('Invalid call, number of argument mismatch')

        try:
            # convert python argument if necessary
            if len(args):
                j_args = <jvalue *>malloc(sizeof(jvalue) * len(d_args))
                if j_args == NULL:
                    raise MemoryError('Unable to allocate memory for java args')
                self.jc.populate_args(self.definition_args, j_args, args)

            # do the call
            if self.is_static:
                return self.call_staticmethod(j_args)
            return self.call_method(j_args)

        finally:
            if j_args != NULL:
                free(j_args)

    cdef call_method(self, jvalue *j_args):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject

        # return type of the java method
        r = self.definition_return[0]

        # now call the java method
        if r == 'V':
            self.j_env[0].CallVoidMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
        elif r == 'Z':
            j_boolean = self.j_env[0].CallBooleanMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].CallByteMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].CallCharMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <char>j_char
        elif r == 'S':
            j_short = self.j_env[0].CallShortMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].CallIntMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].CallLongMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].CallFloatMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].CallDoubleMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            ret = <double>j_double
        elif r == 'L':
            # accept only string for the moment
            j_object = self.j_env[0].CallObjectMethodA(
                    self.j_env, self.j_self, self.j_method, j_args)
            if r == 'Ljava/lang/String;':
                c_str = <char *>self.j_env[0].GetStringUTFChars(
                        self.j_env, j_object, NULL)
                py_str = <bytes>c_str
                self.j_env[0].ReleaseStringUTFChars(
                        self.j_env, j_object, c_str)
                ret = py_str
            else:
                ret_jobject = JavaObject()
                ret_jobject.obj = j_object
                ret = ret_jobject
        elif r == '[':
            # TODO array support
            raise NotImplementedError("Array arguments not implemented")
        else:
            raise Exception('Invalid return definition?')

        return ret

    cdef call_staticmethod(self, jvalue *j_args):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject

        # return type of the java method
        r = self.definition_return[0]

        '''
        print 'TYPE', r
        print 'jenv', 'ok' if self.j_env else 'nop'
        print 'jcls', 'ok' if self.j_cls else 'nop'
        print 'jmethods', 'ok' if self.j_method else 'nop'
        print 'jargs', 'ok' if j_args else 'nop'
        '''

        # now call the java method
        if r == 'V':
            self.j_env[0].CallStaticVoidMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
        elif r == 'Z':
            j_boolean = self.j_env[0].CallStaticBooleanMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].CallStaticByteMethodA
            (self.j_env, self.j_cls, self.j_method, j_args)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].CallStaticCharMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <char>j_char
        elif r == 'S':
            j_short = self.j_env[0].CallStaticShortMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].CallStaticIntMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].CallStaticLongMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].CallStaticFloatMethodA
            (self.j_env, self.j_cls, self.j_method, j_args)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].CallStaticDoubleMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <double>j_double
        elif r == 'L':
            # accept only string for the moment
            j_object = self.j_env[0].CallStaticObjectMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            if r == 'Ljava/lang/String;':
                c_str = <char *>self.j_env[0].GetStringUTFChars(
                        self.j_env, j_object, NULL)
                py_str = <bytes>c_str
                self.j_env[0].ReleaseStringUTFChars(
                        self.j_env, j_object, c_str)
                ret = py_str
            else:
                ret_jobject = JavaObject()
                ret_jobject.obj = j_object
                ret = ret_jobject
        elif r == '[':
            # TODO array support
            raise NotImplementedError("Array arguments not implemented")
        else:
            raise Exception('Invalid return definition?')

        return ret

class JavaStaticMethod(JavaMethod):
    def __init__(self, definition, **kwargs):
        kwargs['static'] = True
        super(JavaStaticMethod, self).__init__(definition, **kwargs)
